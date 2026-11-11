// SPDX-License-Identifier: MIT
import {b64url,encoder} from './security.mjs';

export async function installationToken(env, send=fetch, now=Math.floor(Date.now()/1000)) {
  if (!env.GITHUB_APP_PRIVATE_KEY || !env.GITHUB_CLIENT_ID || !/^[0-9]+$/.test(env.GITHUB_INSTALLATION_ID || '') ||
      !/^[0-9]+$/.test(env.GITHUB_REPOSITORY_ID || '')) throw new Error('GitHub App configuration unavailable');
  // PKCS#8 PEM. Convert the GitHub download locally before storing it as a Worker Secret.
  const pem=env.GITHUB_APP_PRIVATE_KEY.replace(/-----[^-]+-----|\s/g,'');
  const key=await crypto.subtle.importKey('pkcs8',Uint8Array.from(atob(pem),x=>x.charCodeAt(0)),
    {name:'RSASSA-PKCS1-v1_5',hash:'SHA-256'},false,['sign']);
  const input=[{alg:'RS256',typ:'JWT'},{iat:now-60,exp:now+300,iss:env.GITHUB_CLIENT_ID}]
    .map(x=>b64url(encoder.encode(JSON.stringify(x)))).join('.');
  const signature=b64url(new Uint8Array(await crypto.subtle.sign('RSASSA-PKCS1-v1_5',key,encoder.encode(input))));
  const response=await send(`https://api.github.com/app/installations/${env.GITHUB_INSTALLATION_ID}/access_tokens`,{
    method:'POST',redirect:'manual',signal:AbortSignal.timeout(15000),
    headers:{Authorization:`Bearer ${input}.${signature}`,Accept:'application/vnd.github+json','User-Agent':'RetroDOS-Feedback'},
    body:JSON.stringify({repository_ids:[Number(env.GITHUB_REPOSITORY_ID)],permissions:{issues:'write'}})});
  if (!response.ok) throw new Error('GitHub App token unavailable');
  const result=await response.json();
  if (!result.token || result.permissions?.issues !== 'write') throw new Error('GitHub App token unavailable');
  return result.token;
}
