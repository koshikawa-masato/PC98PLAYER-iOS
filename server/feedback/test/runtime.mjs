// Real workerd + D1 integration; external providers are simulated, no email/Issue is sent.
import {Miniflare,convertV4MiniflareOptions,Response as WorkerResponse} from 'miniflare';
import {readFileSync} from 'node:fs';
import assert from 'node:assert/strict';
import {randomToken,sha256} from '../security.mjs';
const origin='https://feedback.three-sisters.ai',base='/v1/feedback';
const mf=new Miniflare(convertV4MiniflareOptions({modules:true,scriptPath:new URL('../dist/worker.js',import.meta.url).pathname,
  compatibilityDate:'2026-11-10',d1Databases:['DB'],
  bindings:{PUBLIC_ORIGIN:origin,RECEPTION_ENABLED:'true',DELIVERY_ENABLED:'false',RATE_HMAC_SECRET:randomToken(),
    GITHUB_CLIENT_ID:'runtime-test-client',GITHUB_CLIENT_SECRET:'runtime-test-secret',GITHUB_APP_ID:'1',
    GITHUB_APP_PRIVATE_KEY:'not-used',GITHUB_INSTALLATION_ID:'123',GITHUB_REPOSITORY_ID:'456'},
  outboundService:async(request)=>{
    if(request.url === 'https://github.com/login/oauth/access_token') return WorkerResponse.json({access_token:'simulated-token',token_type:'bearer'});
    if(request.url === 'https://api.github.com/user') return WorkerResponse.json({id:42,login:'runtime-tester'});
    throw new Error('Unexpected outbound request');
  }}));
try {
  const db=await mf.getD1Database('DB');
  const sql=readFileSync(new URL('../migrations/0001_feedback.sql',import.meta.url),'utf8');
  await db.batch(sql.split(';').map(s=>s.trim()).filter(Boolean).map(s=>db.prepare(s)));
  const state=crypto.randomUUID(),key=crypto.randomUUID(),verifier=randomToken();
  const start=await mf.dispatchFetch(`${origin}${base}/auth/github?`+new URLSearchParams({state,submission_id:key,code_challenge:await sha256(verifier)}),{headers:{'CF-Connecting-IP':'192.0.2.4'},redirect:'manual'});
  assert.equal(start.status,302);
  const cookie=start.headers.get('set-cookie').split(';')[0],oauthState=new URL(start.headers.get('Location')).searchParams.get('state');
  const callback=await mf.dispatchFetch(`${origin}${base}/auth/github/callback?state=${oauthState}&code=simulated-code`,{headers:{Cookie:cookie},redirect:'manual'});
  assert.equal(callback.status,302);const code=new URL(callback.headers.get('Location')).searchParams.get('code');assert.ok(code);
  const payload={title:'workerd runtime verification',body:'Synthetic data only',app_version:'test',os_version:'test',provider:'github',publish_consent:true,auth_code:code,code_verifier:verifier};
  const send=()=>mf.dispatchFetch(`${origin}${base}`,{method:'POST',headers:{'Content-Type':'application/json','Idempotency-Key':key,'CF-Connecting-IP':'192.0.2.4'},body:JSON.stringify(payload)});
  const [a,b]=await Promise.all([send(),send()]);assert.equal(a.status,202);assert.equal(b.status,202);
  assert.equal((await a.json()).receipt,(await b.json()).receipt);
  assert.equal((await db.prepare('SELECT COUNT(*) n FROM reports').first()).n,1);
  assert.equal((await db.prepare('SELECT COUNT(*) n FROM grants WHERE consumed_by IS NOT NULL').first()).n,1);
  console.log('PASS: workerd OAuth callback, D1 atomic grant consumption, concurrent POST deduplication');
} finally {await mf.dispose();}
