// SPDX-License-Identifier: MIT
import {HTTPError,fail,response,sha256,hmac,UUID,CHALLENGE,limitedBody,validateReport} from './security.mjs';
import {BASE,enabledProviders,startAuth,finishAuth} from './oauth.mjs';
import {deliverFeedback} from './delivery.mjs';

async function limit(env, subject, purpose, maximum, now) {
  if (!env.RATE_HMAC_SECRET) fail(503,'temporarily_unavailable');
  const window=Math.floor(now/3600), bucket=await hmac(env.RATE_HMAC_SECRET,`${purpose}:${window}:${subject}`);
  const row=await env.DB.prepare(`INSERT INTO rate_limits(bucket,count,expires_at) VALUES(?,1,?)
    ON CONFLICT(bucket) DO UPDATE SET count=count+1 WHERE count<? RETURNING count`)
    .bind(bucket,(window+1)*3600,maximum).first();
  if (!row) fail(429,'rate_limited');
}
function receiptResponse(row, challenge, digest) {
  if (row.challenge !== challenge || row.digest !== digest) fail(409,'submission_conflict');
  // Receipt is an identifier, never a bearer credential. No public receipt lookup endpoint exists.
  return response({receipt:row.receipt,status:'accepted'},202);
}
export async function acceptReport(request,env,now,ctx,send=fetch) {
  if (request.headers.get('Content-Type')?.split(';')[0].trim() !== 'application/json') fail(415,'json_required');
  const key=request.headers.get('Idempotency-Key') || '';
  if (!UUID.test(key)) fail(400,'invalid_submission_id');
  let data;
  try { data=JSON.parse(await limitedBody(request,2900000)); }
  catch(e) { if(e instanceof HTTPError) throw e; fail(400,'invalid_json'); }
  const report=validateReport(data), challenge=await sha256(data.code_verifier), digest=await sha256(JSON.stringify(report));
  const existing=await env.DB.prepare('SELECT receipt,challenge,digest FROM reports WHERE submission_key=?').bind(key).first();
  if(existing) return receiptResponse(existing,challenge,digest);
  if (!enabledProviders(env)[report.provider]) fail(503,'provider_unavailable');
  if (!CHALLENGE.test(data.auth_code || '')) fail(401,'authentication_required');
  const codeHash=await sha256(data.auth_code);
  const grant=await env.DB.prepare(`SELECT * FROM grants WHERE code_hash=? AND provider=? AND challenge=?
    AND submission_key=? AND expires_at>? AND consumed_by IS NULL`)
    .bind(codeHash,report.provider,challenge,key,now).first();
  if(!grant) {
    // Another request may have committed after our first lookup and consumed the grant.
    const committed=await env.DB.prepare('SELECT receipt,challenge,digest FROM reports WHERE submission_key=?').bind(key).first();
    if(committed) return receiptResponse(committed,challenge,digest);
    fail(401,'authentication_required');
  }
  const ip=request.headers.get('CF-Connecting-IP');
  if(!ip) fail(503,'temporarily_unavailable');
  await limit(env,ip,'send',12,now);
  if(grant.account_json) {
    const account=JSON.parse(grant.account_json);
    await limit(env,`${account.provider}:${account.id}`,'account',12,now);
  }
  const receipt=crypto.randomUUID(), screenshot=report.screenshot_png;
  const stored={...report}; delete stored.screenshot_png;
  const statements=[env.DB.prepare(`INSERT INTO reports
    (submission_key,receipt,challenge,digest,provider,report_json,account_json,created_at,updated_at)
    SELECT ?,?,?,?,?,?,account_json,?,? FROM grants WHERE code_hash=? AND provider=? AND challenge=?
    AND submission_key=? AND expires_at>? AND consumed_by IS NULL ON CONFLICT(submission_key) DO NOTHING`)
    .bind(key,receipt,challenge,digest,report.provider,JSON.stringify(stored),now,now,
      codeHash,report.provider,challenge,key,now)];
  // Private, bounded chunks avoid D1's per-value size limit. Nothing is exposed as a public image URL.
  if(screenshot) for(let p=0;p<screenshot.length;p+=131072) statements.push(env.DB.prepare(
    `INSERT INTO attachments(receipt,part,content) SELECT receipt,?,? FROM reports WHERE receipt=?`)
    .bind(p/131072,screenshot.slice(p,p+131072),receipt));
  statements.push(env.DB.prepare(`UPDATE grants SET consumed_by=? WHERE code_hash=? AND consumed_by IS NULL
    AND EXISTS(SELECT 1 FROM reports WHERE receipt=?)`).bind(receipt,codeHash,receipt));
  await env.DB.batch(statements);
  const accepted=await env.DB.prepare('SELECT receipt,challenge,digest FROM reports WHERE submission_key=?').bind(key).first();
  if(!accepted) fail(401,'authentication_required');
  const result=receiptResponse(accepted,challenge,digest);
  if(ctx && env.DELIVERY_ENABLED === 'true') ctx.waitUntil(deliverPending(env,send));
  return result;
}

export async function deliverPending(env,send=fetch,now=Math.floor(Date.now()/1000)) {
  if(env.DELIVERY_ENABLED !== 'true') return;
  // A process can disappear after an external side effect. Do not blindly resend uncertain messages.
  await env.DB.prepare(`UPDATE reports SET status='needs_review',updated_at=? WHERE status='delivering' AND updated_at<?`)
    .bind(now,now-300).run();
  const pending=await env.DB.prepare(`SELECT receipt FROM reports WHERE status='pending' ORDER BY created_at LIMIT 4`).all();
  for(const item of pending.results) {
    const row=await env.DB.prepare(`UPDATE reports SET status='delivering',updated_at=?
      WHERE receipt=? AND status='pending' RETURNING *`).bind(now,item.receipt).first();
    if(!row) continue;
    try {
      const report=JSON.parse(row.report_json);
      const image=await env.DB.prepare('SELECT content FROM attachments WHERE receipt=? ORDER BY part').bind(row.receipt).all();
      if(image.results.length) report.screenshot_png=image.results.map(x=>x.content).join('');
      const result=await deliverFeedback(env,report,row.account_json ? JSON.parse(row.account_json) : null,row.receipt,send);
      await env.DB.prepare(`UPDATE reports SET status='delivered',result_json=?,updated_at=? WHERE receipt=?`)
        .bind(JSON.stringify(result),now,row.receipt).run();
    } catch {
      await env.DB.prepare(`UPDATE reports SET status='needs_review',updated_at=? WHERE receipt=?`).bind(now,row.receipt).run();
    }
  }
}
export async function cleanup(env,now) {
  await env.DB.batch([
    env.DB.prepare('DELETE FROM auth_transactions WHERE expires_at<=?').bind(now),
    env.DB.prepare('DELETE FROM grants WHERE expires_at<=?').bind(now),
    env.DB.prepare('DELETE FROM rate_limits WHERE expires_at<=?').bind(now),
    env.DB.prepare('DELETE FROM reports WHERE created_at<?').bind(now-30*86400)
  ]);
}
export async function handle(request,env,ctx,send=fetch,now=Math.floor(Date.now()/1000)) {
  try {
    const url=new URL(request.url);
    if(!env.PUBLIC_ORIGIN || url.origin !== env.PUBLIC_ORIGIN || url.protocol !== 'https:') fail(404,'not_found');
    if(url.pathname === '/health' && request.method === 'GET') return response({service:'retrodos-feedback',ok:true});
    if(url.pathname === `${BASE}/capabilities` && request.method === 'GET')
      return response({providers:env.RECEPTION_ENABLED === 'true' ? enabledProviders(env) : {anonymous:false,github:false,x:false}});
    if(env.RECEPTION_ENABLED !== 'true' || !env.DB) fail(503,'temporarily_unavailable');
    const origin=request.headers.get('Origin');
    // Safari may send Origin:null for a no-referrer form navigation. Only this
    // callback allows it; a host-only cookie, single-use state and Turnstile still bind it.
    const opaqueAnonymousCallback=origin === 'null' && request.method === 'POST' &&
      url.pathname === `${BASE}/auth/anonymous/callback`;
    if(origin && origin !== env.PUBLIC_ORIGIN && !opaqueAnonymousCallback) fail(403,'invalid_origin');
    if(url.pathname === BASE && request.method === 'POST') return await acceptReport(request,env,now,ctx,send);
    const route=url.pathname.match(/^\/v1\/feedback\/auth\/(anonymous|github|x)(\/callback)?$/);
    if(!route) fail(404,'not_found');
    const [,provider,callback]=route;
    if(!callback && request.method === 'GET') {
      const ip=request.headers.get('CF-Connecting-IP'); if(!ip) fail(503,'temporarily_unavailable');
      await limit(env,ip,'login',30,now);
      return await startAuth(request,env,provider,now);
    }
    if(callback && provider === 'anonymous' && request.method === 'POST') {
      if(request.headers.get('Content-Type')?.split(';')[0].trim() !== 'application/x-www-form-urlencoded') fail(415,'form_required');
      return await finishAuth(request,env,provider,new URLSearchParams(await limitedBody(request,5000)),now,send);
    }
    if(callback && provider !== 'anonymous' && request.method === 'GET')
      return await finishAuth(request,env,provider,url.searchParams,now,send);
    fail(405,'method_not_allowed');
  } catch(e) {
    // Do not return provider bodies, URLs, tokens, stack traces, or submitted content.
    return response({error:e instanceof HTTPError ? e.code : 'temporarily_unavailable'},e instanceof HTTPError ? e.status : 503);
  }
}
export default {
  fetch:handle,
  async scheduled(controller,env,ctx) {
    if(!env.DB) return;
    ctx.waitUntil((async()=>{await deliverPending(env);await cleanup(env,Math.floor(Date.now()/1000));})());
  }
};
