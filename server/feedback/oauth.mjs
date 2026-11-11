// SPDX-License-Identifier: MIT
import {fail, param, randomToken, sha256, CHALLENGE, UUID, PROVIDERS} from './security.mjs';

export const BASE = '/v1/feedback';
const APP_RETURN = 'retrodos-feedback://callback';
export const callbackURL = (env, provider) => `${env.PUBLIC_ORIGIN}${BASE}/auth/${provider}/callback`;
export function enabledProviders(env) {
  return {
    anonymous: !!(env.TURNSTILE_SITE_KEY && env.TURNSTILE_SECRET),
    github: !!(env.GITHUB_CLIENT_ID && env.GITHUB_CLIENT_SECRET && env.GITHUB_APP_ID &&
      env.GITHUB_APP_PRIVATE_KEY && env.GITHUB_INSTALLATION_ID && env.GITHUB_REPOSITORY_ID),
    x: !!(env.X_CLIENT_ID && env.X_CLIENT_SECRET)
  };
}
const cookieName = (state) => `__Host-rd-${state}`;
function cookie(request, name) {
  const matches = (request.headers.get('Cookie') || '').split(';').map(x => x.trim()).filter(x => x.startsWith(`${name}=`));
  return matches.length === 1 ? matches[0].slice(name.length+1) : '';
}
function redirect(url, cookieValue) {
  const headers = {'Location':url,'Cache-Control':'no-store','Referrer-Policy':'no-referrer'};
  if (cookieValue) headers['Set-Cookie'] = cookieValue;
  return new Response(null, {status:302, headers});
}
function appReturn(tx, state, result) {
  const url = new URL(APP_RETURN);
  url.searchParams.set('state', tx.app_state);
  url.searchParams.set('provider', tx.provider);
  for (const [key,value] of Object.entries(result)) url.searchParams.set(key,value);
  return redirect(url.href, `${cookieName(state)}=; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=0`);
}
export async function startAuth(request, env, provider, now) {
  if (!PROVIDERS.includes(provider) || !enabledProviders(env)[provider]) fail(503, 'provider_unavailable');
  const params = new URL(request.url).searchParams;
  if ([...params.keys()].some(k=>!['state','code_challenge','submission_id'].includes(k))) fail(400,'invalid_request');
  const appState=param(params,'state'), challenge=param(params,'code_challenge'), submissionKey=param(params,'submission_id');
  if (!UUID.test(appState) || !CHALLENGE.test(challenge) || !UUID.test(submissionKey)) fail(400,'invalid_request');
  const state=randomToken(), browser=randomToken(), verifier=randomToken();
  await env.DB.prepare(`INSERT INTO auth_transactions
    (state_hash,provider,app_state,challenge,submission_key,browser_hash,provider_verifier,expires_at)
    VALUES(?,?,?,?,?,?,?,?)`).bind(await sha256(state),provider,appState,challenge,submissionKey,
      await sha256(browser),verifier,now+600).run();
  const setCookie=`${cookieName(state)}=${browser}; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=600`;
  if (provider === 'anonymous') return turnstilePage(env,state,setCookie);
  const url=new URL(provider === 'github' ? 'https://github.com/login/oauth/authorize' : 'https://x.com/i/oauth2/authorize');
  url.search = new URLSearchParams({client_id:provider === 'github' ? env.GITHUB_CLIENT_ID : env.X_CLIENT_ID,
    response_type:'code',state,redirect_uri:callbackURL(env,provider),
    code_challenge:await sha256(verifier),code_challenge_method:'S256'}).toString();
  // GitHub App: no account/email/repo OAuth scopes. X: /2/users/me requires these read scopes.
  if (provider === 'x') url.searchParams.set('scope','tweet.read users.read');
  return redirect(url.href,setCookie);
}
function turnstilePage(env,state,setCookie) {
  if (!/^[A-Za-z0-9_-]+$/.test(env.TURNSTILE_SITE_KEY)) fail(503,'provider_unavailable');
  const nonce=randomToken();
  const html=`<!doctype html><html lang="ja"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>RetroDOS Player 送信確認</title><body><h1>報告の送信確認</h1><p>確認が終わるとアプリへ戻ります。ログインは不要です。</p>
<form method="post" action="${BASE}/auth/anonymous/callback"><input type="hidden" name="state" value="${state}">
<div class="cf-turnstile" data-sitekey="${env.TURNSTILE_SITE_KEY}" data-action="feedback" data-cdata="${state}" data-callback="ready"></div>
<button id="continue" disabled>アプリへ戻る</button></form><script nonce="${nonce}">window.ready=()=>{document.getElementById('continue').disabled=false;};</script>
<script src="https://challenges.cloudflare.com/turnstile/v0/api.js" async defer></script></body></html>`;
  return new Response(html,{headers:{'Content-Type':'text/html; charset=utf-8','Cache-Control':'no-store',
    'Referrer-Policy':'no-referrer','X-Content-Type-Options':'nosniff','Set-Cookie':setCookie,
    'Content-Security-Policy':`default-src 'none'; script-src 'nonce-${nonce}' https://challenges.cloudflare.com; frame-src https://challenges.cloudflare.com; connect-src https://challenges.cloudflare.com; form-action 'self' retrodos-feedback://callback; base-uri 'none'; frame-ancestors 'none'`}});
}
async function providerJSON(url, options, send) {
  const res=await send(url,{...options,redirect:'manual',signal:AbortSignal.timeout(15000)});
  if (!res.ok) throw new Error('Provider request failed');
  return res.json();
}
export async function finishAuth(request, env, provider, params, now, send=fetch) {
  const state=param(params,'state');
  if (!CHALLENGE.test(state) || !PROVIDERS.includes(provider)) fail(400,'invalid_auth');
  const browser=cookie(request,cookieName(state));
  if (!CHALLENGE.test(browser)) fail(400,'invalid_auth');
  // DELETE RETURNING is atomic, preventing two callbacks from exchanging the same transaction.
  const tx=await env.DB.prepare(`DELETE FROM auth_transactions WHERE state_hash=? AND provider=?
    AND browser_hash=? AND expires_at>? RETURNING *`).bind(await sha256(state),provider,await sha256(browser),now).first();
  if (!tx) fail(400,'invalid_auth');
  if (params.has('error')) return appReturn(tx,state,{error:params.get('error') === 'access_denied' ? 'cancelled' : 'authentication_failed'});
  try {
    let account=null;
    if (provider === 'anonymous') {
      const token=param(params,'cf-turnstile-response');
      if (!token || token.length>2048) throw new Error('Invalid human verification');
      const result=await providerJSON('https://challenges.cloudflare.com/turnstile/v0/siteverify',{
        method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},
        body:new URLSearchParams({secret:env.TURNSTILE_SECRET,response:token})},send);
      if (result.success !== true || result.hostname !== new URL(env.PUBLIC_ORIGIN).hostname ||
          result.action !== 'feedback' || result.cdata !== state) throw new Error('Invalid human verification');
    } else {
      const code=param(params,'code');
      if (!code || code.length>1024) throw new Error('Invalid provider code');
      const github=provider === 'github';
      const credentials={client_id:github ? env.GITHUB_CLIENT_ID : env.X_CLIENT_ID,
        code,grant_type:'authorization_code',redirect_uri:callbackURL(env,provider),code_verifier:tx.provider_verifier};
      const headers={'Content-Type':'application/x-www-form-urlencoded',Accept:'application/json','User-Agent':'RetroDOS-Feedback'};
      if (github) credentials.client_secret=env.GITHUB_CLIENT_SECRET;
      else headers.Authorization=`Basic ${btoa(`${encodeURIComponent(env.X_CLIENT_ID)}:${encodeURIComponent(env.X_CLIENT_SECRET)}`)}`;
      const tokens=await providerJSON(github ? 'https://github.com/login/oauth/access_token' : 'https://api.x.com/2/oauth2/token',
        {method:'POST',headers,body:new URLSearchParams(credentials)},send);
      if (typeof tokens.access_token !== 'string' || tokens.token_type?.toLowerCase() !== 'bearer') throw new Error('Invalid provider token');
      const profile=await providerJSON(github ? 'https://api.github.com/user' : 'https://api.x.com/2/users/me',
        {headers:{Authorization:`Bearer ${tokens.access_token}`,Accept:'application/json','User-Agent':'RetroDOS-Feedback'}},send);
      const id=github ? profile.id : profile.data?.id, handle=github ? profile.login : profile.data?.username;
      if (!/^[0-9]{1,32}$/.test(String(id)) || typeof handle !== 'string' ||
          !(github ? /^[A-Za-z0-9-]{1,39}$/ : /^[A-Za-z0-9_]{1,15}$/).test(handle)) throw new Error('Invalid identity');
      account={provider,id:String(id),handle};
      // Tokens remain in this invocation only, never in the app, database, redirects or logs.
    }
    const code=randomToken();
    await env.DB.prepare(`INSERT INTO grants(code_hash,provider,challenge,submission_key,account_json,expires_at)
      VALUES(?,?,?,?,?,?)`).bind(await sha256(code),provider,tx.challenge,tx.submission_key,
        account ? JSON.stringify(account) : null,now+300).run();
    return appReturn(tx,state,{code});
  } catch {
    return appReturn(tx,state,{error:'authentication_failed'});
  }
}
