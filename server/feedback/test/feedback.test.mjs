// SPDX-License-Identifier: MIT
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {DatabaseSync} from 'node:sqlite';
import {readFileSync} from 'node:fs';
import {deflateSync} from 'node:zlib';
import {handle,deliverPending,cleanup} from '../worker.mjs';
import {randomToken,sha256,validatePNG} from '../security.mjs';
import {BASE} from '../oauth.mjs';
import {installationToken} from '../github.mjs';

const ORIGIN='https://feedback.three-sisters.ai', NOW=1800000000;
class D1 {
  constructor() {this.db=new DatabaseSync(':memory:');this.db.exec('PRAGMA foreign_keys=ON;'+readFileSync(new URL('../migrations/0001_feedback.sql',import.meta.url),'utf8'));}
  prepare(sql) {
    const stmt=this.db.prepare(sql);
    const make=(args)=>({bind:(...next)=>make(next),
      first:async()=>stmt.get(...args) ?? null,
      all:async()=>({results:stmt.all(...args)}),
      run:async()=>({meta:{changes:Number(stmt.run(...args).changes)}})});
    return make([]);
  }
  async batch(statements) {this.db.exec('BEGIN');try{const result=[];for(const s of statements) result.push(await s.run());this.db.exec('COMMIT');return result;}catch(e){this.db.exec('ROLLBACK');throw e;}}
}
function setup() {
  const emails=[];
  const env={DB:new D1(),PUBLIC_ORIGIN:ORIGIN,RECEPTION_ENABLED:'true',DELIVERY_ENABLED:'false',RATE_HMAC_SECRET:randomToken(),
    TURNSTILE_SITE_KEY:'test-site-key',TURNSTILE_SECRET:'test-only-secret',
    GITHUB_CLIENT_ID:'test-client',GITHUB_CLIENT_SECRET:'test-only-secret',GITHUB_APP_ID:'1',
    GITHUB_APP_PRIVATE_KEY:'test-placeholder',GITHUB_INSTALLATION_ID:'123',GITHUB_REPOSITORY_ID:'456',
    X_CLIENT_ID:'test-x-client',X_CLIENT_SECRET:'test-only-secret',FEEDBACK_FROM:'feedback@three-sisters.ai',
    EMAIL:{send:async(message)=>{emails.push(message);return{messageId:'test-message'};}}};
  return {env,emails};
}
function req(path,options={}) {return new Request(ORIGIN+path,{...options,headers:{'CF-Connecting-IP':'192.0.2.1',...options.headers}});}
const forbiddenFetch=async()=>{throw new Error('Unexpected external request');};
async function start(env,provider='github',options={}) {
  const verifier=options.verifier || randomToken(),key=options.key || crypto.randomUUID(),appState=crypto.randomUUID();
  const response=await handle(req(`${BASE}/auth/${provider}?`+new URLSearchParams({state:appState,
    code_challenge:await sha256(verifier),submission_id:key})),env,null,forbiddenFetch,NOW);
  assert.equal(response.status,provider === 'anonymous' ? 200 : 302);
  const cookie=response.headers.get('Set-Cookie').split(';')[0];
  const state=cookie.slice('__Host-rd-'.length).split('=')[0];
  return {provider,verifier,key,appState,cookie,state,response};
}
async function finish(env,flow,{error,now=NOW,override={},cookie=flow.cookie}={}) {
  const seen=[];
  const mock=async(url,opts)=>{
    seen.push({url:String(url),opts});
    assert.equal(opts.redirect,'manual');
    const value=override[String(url)] || (String(url).includes('siteverify') ? {success:true,hostname:new URL(ORIGIN).hostname,action:'feedback',cdata:flow.state} :
      String(url).endsWith('/user') ? {id:42,login:'tester'} : String(url).endsWith('/users/me') ? {data:{id:'77',username:'tester_x'}} :
      {access_token:'test-user-token',token_type:'bearer'});
    return Response.json(value);
  };
  const params=new URLSearchParams({state:flow.state,...(error ? {error} : flow.provider === 'anonymous' ? {'cf-turnstile-response':'test-human-token'} : {code:'test-provider-code'})});
  const request=flow.provider === 'anonymous' ? req(`${BASE}/auth/anonymous/callback`,{method:'POST',headers:{Cookie:cookie,'Content-Type':'application/x-www-form-urlencoded'},body:params}) :
    req(`${BASE}/auth/${flow.provider}/callback?${params}`,{headers:{Cookie:cookie}});
  const response=await handle(request,env,null,mock,now);
  const location=response.headers.get('Location');
  return {response,seen,code:location ? new URL(location).searchParams.get('code') : null,location};
}
async function authorized(env,provider='github',options={}) {const flow=await start(env,provider,options);const done=await finish(env,flow);assert.equal(done.response.status,302);assert.ok(done.code);return{...flow,code:done.code,seen:done.seen};}
function report(flow,changes={}) {return{title:'受付検証',body:'テスト用の報告です。',app_version:'0.2.4 (test)',os_version:'27.1',
  provider:flow.provider,auth_code:flow.code,code_verifier:flow.verifier,...(flow.provider === 'github' ? {publish_consent:true} : {}),...changes};}
function submit(env,flow,changes={},now=NOW) {return handle(req(BASE,{method:'POST',headers:{'Content-Type':'application/json','Idempotency-Key':flow.key},body:JSON.stringify(report(flow,changes))}),env,null,forbiddenFetch,now);}
function png(width=1,height=1) {
  const chunk=(type,body)=>{const data=Buffer.concat([Buffer.from(type),body]);let crc=0xffffffff;for(const n of data){crc^=n;for(let i=0;i<8;i++)crc=(crc>>>1)^((crc&1)?0xedb88320:0);}const len=Buffer.alloc(4),sum=Buffer.alloc(4);len.writeUInt32BE(body.length);sum.writeUInt32BE((crc^0xffffffff)>>>0);return Buffer.concat([len,data,sum]);};
  const hdr=Buffer.alloc(13);hdr.writeUInt32BE(width);hdr.writeUInt32BE(height,4);hdr[8]=8;hdr[9]=6;
  return Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]),chunk('IHDR',hdr),chunk('IDAT',deflateSync(Buffer.from([0,0,0,0,255]))),chunk('IEND',Buffer.alloc(0))]).toString('base64');
}

test('GitHub flow: independent state/PKCE, secure cookie, fresh identity, no tokens persisted',async()=>{
  const {env}=setup(),flow=await authorized(env);
  const location=new URL(flow.response.headers.get('Location'));
  assert.notEqual(flow.state,flow.appState);assert.notEqual(location.searchParams.get('code_challenge'),await sha256(flow.verifier));
  assert.equal(location.searchParams.get('code_challenge_method'),'S256');assert.equal(location.searchParams.get('scope'),null);
  assert.match(flow.response.headers.get('Set-Cookie'),/Secure; HttpOnly; SameSite=Lax/);
  assert.equal(flow.seen[1].url,'https://api.github.com/user');
  const grants=env.DB.db.prepare('SELECT * FROM grants').all();assert.equal(grants.length,1);
  assert.deepEqual(JSON.parse(grants[0].account_json),{provider:'github',id:'42',handle:'tester'});
  assert.ok(!JSON.stringify(grants).includes('test-user-token'));assert.ok(!JSON.stringify(grants).includes(flow.code));
});
test('X uses read-only scopes and confidential code exchange',async()=>{
  const {env}=setup(),flow=await authorized(env,'x');
  assert.equal(new URL(flow.response.headers.get('Location')).searchParams.get('scope'),'tweet.read users.read');
  assert.match(flow.seen[0].opts.headers.Authorization,/^Basic /);assert.equal(flow.seen[1].url,'https://api.x.com/2/users/me');
});
test('cancel returns to initiating app state; callback cannot be replayed',async()=>{
  const {env}=setup(),flow=await start(env);const done=await finish(env,flow,{error:'access_denied'});
  const u=new URL(done.location);assert.equal(u.searchParams.get('error'),'cancelled');assert.equal(u.searchParams.get('state'),flow.appState);
  assert.equal(done.seen.length,0);assert.equal((await finish(env,flow)).response.status,400);
});
test('missing browser binding is rejected without consuming real session',async()=>{
  const {env}=setup(),flow=await start(env);assert.equal((await finish(env,flow,{cookie:''})).response.status,400);assert.ok((await finish(env,flow)).code);
});
test('incorrect browser binding cannot substitute an account',async()=>{
  const {env}=setup(),flow=await start(env);assert.equal((await finish(env,flow,{cookie:flow.cookie.split('=')[0]+'='+randomToken()})).response.status,400);
});
test('expired transaction and duplicate state parameters fail',async()=>{
  const {env}=setup(),flow=await start(env);assert.equal((await finish(env,flow,{now:NOW+601})).response.status,400);
  const r=await handle(req(`${BASE}/auth/github/callback?state=${flow.state}&state=${flow.state}&code=x`,{headers:{Cookie:flow.cookie}}),env,null,forbiddenFetch,NOW);
  assert.equal(r.status,400);
});
test('provider mix-up is rejected',async()=>{
  const {env}=setup(),flow=await start(env);assert.equal((await finish(env,{...flow,provider:'x'})).response.status,400);
});
test('invalid provider profile never creates authenticated grant',async()=>{
  const {env}=setup(),flow=await start(env);const result=await finish(env,flow,{override:{'https://api.github.com/user':{id:42,login:'[spoof](url)'}}});
  assert.equal(new URL(result.location).searchParams.get('error'),'authentication_failed');assert.equal(env.DB.db.prepare('SELECT COUNT(*) n FROM grants').get().n,0);
});
test('Turnstile verifies action, hostname and transaction binding on server',async()=>{
  for(const field of ['hostname','action','cdata','success']) {
    const {env}=setup(),flow=await start(env,'anonymous');const value={success:true,hostname:new URL(ORIGIN).hostname,action:'feedback',cdata:flow.state,[field]:'wrong'};
    const result=await finish(env,flow,{override:{'https://challenges.cloudflare.com/turnstile/v0/siteverify':value}});
    assert.equal(new URL(result.location).searchParams.get('error'),'authentication_failed');
  }
});
test('anonymous report requires verified grant, never client-supplied identity',async()=>{
  const {env}=setup(),flow=await authorized(env,'anonymous');assert.equal((await submit(env,flow,{auth_code:''})).status,401);
  assert.equal((await submit(env,flow,{account:{handle:'admin'}})).status,400);assert.equal((await submit(env,flow)).status,202);
});
test('public GitHub submission requires explicit consent',async()=>{
  const {env}=setup(),flow=await authorized(env);assert.equal((await submit(env,flow,{publish_consent:false})).status,400);
});
test('wrong PKCE, expiry, provider or submission ID cannot consume grant',async()=>{
  const {env}=setup(),flow=await authorized(env);
  assert.equal((await submit(env,flow,{code_verifier:randomToken()})).status,401);
  assert.equal((await submit(env,flow,{provider:'x'})).status,401);
  assert.equal((await submit(env,{...flow,key:crypto.randomUUID()})).status,401);
  assert.equal((await submit(env,flow,{},NOW+301)).status,401);
  assert.equal((await submit(env,flow)).status,202);
});
test('same report retries receive same receipt; cannot use receipt as an access token',async()=>{
  const {env}=setup(),flow=await authorized(env);const first=await (await submit(env,flow)).json();
  const again=await (await submit(env,flow,{auth_code:undefined})).json();assert.equal(first.receipt,again.receipt);
  assert.equal((await submit(env,flow,{code_verifier:randomToken()})).status,409);
  assert.equal((await handle(req('/receipts/'+first.receipt),env,null,forbiddenFetch,NOW)).status,404);
  assert.equal(env.DB.db.prepare('SELECT COUNT(*) n FROM reports').get().n,1);
});
test('changing report body for a used submission ID fails',async()=>{
  const {env}=setup(),flow=await authorized(env);await submit(env,flow);assert.equal((await submit(env,flow,{body:'changed'})).status,409);
});
test('parallel duplicate POSTs result in one durable report',async()=>{
  const {env}=setup(),flow=await authorized(env);const results=await Promise.all([submit(env,flow),submit(env,flow)]);
  const data=await Promise.all(results.map(x=>x.json()));assert.equal(data[0].receipt,data[1].receipt);assert.ok(data[0].receipt);
  assert.equal(env.DB.db.prepare('SELECT COUNT(*) n FROM reports').get().n,1);
});
test('accepted report survives response loss and authentication expiry',async()=>{
  const {env}=setup(),flow=await authorized(env);await submit(env,flow);const count=env.DB.db.prepare('SELECT COUNT(*) n FROM reports').get().n;
  assert.equal(count,1);assert.equal((await submit(env,flow,{},NOW+1000)).status,202);
});
test('oversized JSON and forged content type are rejected before delivery',async()=>{
  const {env}=setup(),flow=await authorized(env);
  const response=await handle(req(BASE,{method:'POST',headers:{'Content-Type':'application/json','Content-Length':'3000000','Idempotency-Key':flow.key},body:'{}'}),env,null,forbiddenFetch,NOW);
  assert.equal(response.status,413);
  assert.equal((await handle(req(BASE,{method:'POST',body:'{}'}),env,null,forbiddenFetch,NOW)).status,415);
  assert.equal((await submit(env,flow,{body:'x'.repeat(8001)})).status,400);
});
test('PNG validation rejects disguised data, bad CRC and decompression dimensions',()=>{
  assert.doesNotThrow(()=>validatePNG(png()));
  const corrupt=Buffer.from(png(),'base64');corrupt[35]^=1;
  for(const bad of [Buffer.from('<script>x</script>').toString('base64'),png(100000,100000),png().slice(0,-4),corrupt.toString('base64')]) {
    assert.throws(()=>validatePNG(bad));
  }
});
test('screenshots remain private and anonymous/X are only emailed to fixed recipient',async()=>{
  for(const provider of ['anonymous','x']) {
    const {env,emails}=setup(),flow=await authorized(env,provider);const image=png();await submit(env,flow,{screenshot_png:image});
    env.DELIVERY_ENABLED='true';await deliverPending(env,forbiddenFetch,NOW);await deliverPending(env,forbiddenFetch,NOW);
    assert.equal(emails.length,1);assert.equal(emails[0].to,'firecracker.rebirth@gmail.com');assert.equal(emails[0].attachments[0].content,image);
    assert.match(emails[0].text,provider === 'x' ? /X @tester_x/ : /匿名/);
  }
});
test('uncertain delivery is held for review, not automatically duplicated',async()=>{
  const {env}=setup(),flow=await authorized(env,'anonymous');await submit(env,flow);
  let attempts=0;env.EMAIL.send=async()=>{attempts++;throw new Error('response lost after send');};env.DELIVERY_ENABLED='true';
  await deliverPending(env,forbiddenFetch,NOW);await deliverPending(env,forbiddenFetch,NOW+400);
  assert.equal(attempts,1);assert.equal(env.DB.db.prepare('SELECT status FROM reports').get().status,'needs_review');
});
test('delivery disabled never calls a provider',async()=>{
  const {env,emails}=setup(),flow=await authorized(env,'anonymous');await submit(env,flow);await deliverPending(env,forbiddenFetch,NOW);assert.equal(emails.length,0);
});
test('rate limit uses pseudonymous expiring buckets',async()=>{
  const {env}=setup();for(let n=0;n<30;n++) await start(env);
  const result=await handle(req(`${BASE}/auth/github?state=${crypto.randomUUID()}&code_challenge=${randomToken()}&submission_id=${crypto.randomUUID()}`),env,null,forbiddenFetch,NOW);
  assert.equal(result.status,429);assert.ok(!JSON.stringify(env.DB.db.prepare('SELECT * FROM rate_limits').all()).includes('192.0.2.1'));
});
test('unknown origin and foreign browser origins cannot submit',async()=>{
  const {env}=setup();assert.equal((await handle(new Request('https://evil.example/health'),env,null,forbiddenFetch,NOW)).status,404);
  assert.equal((await handle(req(BASE,{method:'POST',headers:{Origin:'https://evil.example'}}),env,null,forbiddenFetch,NOW)).status,403);
});
test('unconfigured providers fail closed and are advertised as unavailable',async()=>{
  const {env}=setup();delete env.GITHUB_CLIENT_SECRET;
  const res=await handle(req(`${BASE}/capabilities`),env,null,forbiddenFetch,NOW);assert.equal((await res.json()).providers.github,false);
  const r=await handle(req(`${BASE}/auth/github?state=${crypto.randomUUID()}&code_challenge=${randomToken()}&submission_id=${crypto.randomUUID()}`),env,null,forbiddenFetch,NOW);assert.equal(r.status,503);
});
test('cleanup removes expired sessions and reports including private attachments',async()=>{
  const {env}=setup(),flow=await authorized(env,'anonymous');await submit(env,flow,{screenshot_png:png()});await cleanup(env,NOW+31*86400);
  for(const table of ['reports','attachments','grants','auth_transactions','rate_limits']) assert.equal(env.DB.db.prepare(`SELECT COUNT(*) n FROM ${table}`).get().n,0);
});
test('GitHub App mints short-lived signed JWT and repository-limited Issues token',async()=>{
  const {env}=setup();const keys=await crypto.subtle.generateKey({name:'RSASSA-PKCS1-v1_5',modulusLength:2048,publicExponent:new Uint8Array([1,0,1]),hash:'SHA-256'},true,['sign','verify']);
  env.GITHUB_APP_PRIVATE_KEY='-----BEGIN PRIVATE KEY-----\n'+Buffer.from(await crypto.subtle.exportKey('pkcs8',keys.privateKey)).toString('base64')+'\n-----END PRIVATE KEY-----';
  const mock=async(url,options)=>{
    assert.equal(url,'https://api.github.com/app/installations/123/access_tokens');
    assert.deepEqual(JSON.parse(options.body),{repository_ids:[456],permissions:{issues:'write'}});
    const jwt=options.headers.Authorization.slice(7).split('.');const payload=JSON.parse(Buffer.from(jwt[1],'base64url'));
    assert.equal(payload.exp,NOW+300);assert.equal(payload.iss,env.GITHUB_CLIENT_ID);
    assert.ok(await crypto.subtle.verify('RSASSA-PKCS1-v1_5',keys.publicKey,Buffer.from(jwt[2],'base64url'),Buffer.from(jwt.slice(0,2).join('.'))));
    return Response.json({token:'test-installation-token',permissions:{issues:'write'}});
  };
  assert.equal(await installationToken(env,mock,NOW),'test-installation-token');
});


test('provider redirects are rejected without forwarding credentials',async()=>{
  const {env}=setup(),flow=await start(env);
  let calls=0;
  const response=await handle(req(`${BASE}/auth/github/callback?state=${flow.state}&code=test-code`,{headers:{Cookie:flow.cookie}}),env,null,async(url,opts)=>{
    calls++;assert.equal(opts.redirect,'manual');
    return new Response(null,{status:302,headers:{Location:'https://untrusted.invalid/'}});
  },NOW);
  assert.equal(calls,1);assert.equal(new URL(response.headers.get('Location')).searchParams.get('error'),'authentication_failed');
  assert.equal(env.DB.db.prepare('SELECT COUNT(*) n FROM grants').get().n,0);
});

test('a retry racing a committed grant returns the original receipt',async()=>{
  const {env}=setup(),flow=await authorized(env);
  const first=await (await submit(env,flow)).json();
  const original=env.DB.prepare.bind(env.DB);let skipped=false;
  env.DB.prepare=(sql)=>{
    const stmt=original(sql);
    if(!skipped && sql==='SELECT receipt,challenge,digest FROM reports WHERE submission_key=?') {
      skipped=true;return {bind:()=>({first:async()=>null})};
    }
    return stmt;
  };
  const retry=await submit(env,flow);assert.equal(retry.status,202);assert.equal((await retry.json()).receipt,first.receipt);
});

test('Safari opaque Origin is allowed only for cookie-bound anonymous callback',async()=>{
  const {env}=setup(),flow=await start(env,'anonymous');
  const form=new URLSearchParams({state:flow.state,'cf-turnstile-response':'test-human-token'});
  const send=async()=>Response.json({success:true,hostname:new URL(ORIGIN).hostname,action:'feedback',cdata:flow.state});
  const callback=(cookie)=>req(`${BASE}/auth/anonymous/callback`,{method:'POST',headers:{Origin:'null',Cookie:cookie,'Content-Type':'application/x-www-form-urlencoded'},body:form});
  assert.equal((await handle(callback(''),env,null,send,NOW)).status,400);
  const result=await handle(callback(flow.cookie),env,null,send,NOW);
  assert.ok(new URL(result.headers.get('Location')).searchParams.get('code'));
  assert.equal((await handle(req(BASE,{method:'POST',headers:{Origin:'null','Content-Type':'application/json'},body:'{}'}),env,null,send,NOW)).status,403);
});


test('anonymous form permits only the service and fixed app callback destination',async()=>{
  const {env}=setup(),flow=await start(env,'anonymous');
  assert.match(flow.response.headers.get('Content-Security-Policy'),/form-action 'self' retrodos-feedback:\/\/callback;/);
});
