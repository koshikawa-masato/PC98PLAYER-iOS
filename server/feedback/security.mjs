// SPDX-License-Identifier: MIT
export class HTTPError extends Error {
  constructor(status, code) { super(code); this.status = status; this.code = code; }
}
export const fail = (status, code) => { throw new HTTPError(status, code); };
export const encoder = new TextEncoder();
export const b64url = (bytes) => btoa(String.fromCharCode(...bytes))
  .replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
export const randomToken = () => b64url(crypto.getRandomValues(new Uint8Array(32)));
export const sha256 = async (text) => b64url(new Uint8Array(await crypto.subtle.digest('SHA-256', encoder.encode(text))));
export async function hmac(secret, text) {
  const key = await crypto.subtle.importKey('raw', encoder.encode(secret), {name:'HMAC', hash:'SHA-256'}, false, ['sign']);
  return b64url(new Uint8Array(await crypto.subtle.sign('HMAC', key, encoder.encode(text))));
}
export const UUID = /^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/i;
export const CHALLENGE = /^[A-Za-z0-9_-]{43}$/;
export const VERIFIER = /^[A-Za-z0-9._~-]{43,128}$/;
export const PROVIDERS = ['anonymous','github','x'];
export function param(params, name) {
  const values = params.getAll(name);
  if (values.length !== 1) fail(400, 'invalid_request');
  return values[0];
}
export function response(data, status = 200, extra = {}) {
  return new Response(JSON.stringify(data), {status, headers:{
    'Content-Type':'application/json; charset=utf-8', 'Cache-Control':'no-store',
    'Referrer-Policy':'no-referrer', 'X-Content-Type-Options':'nosniff', ...extra
  }});
}
export async function limitedBody(request, maximum) {
  if (Number(request.headers.get('Content-Length')) > maximum) fail(413, 'report_too_large');
  const reader = request.body?.getReader();
  if (!reader) fail(400, 'invalid_request');
  const chunks = []; let size = 0;
  try {
    while (true) {
      const {value, done} = await reader.read(); if (done) break;
      size += value.length;
      if (size > maximum) { await reader.cancel(); fail(413, 'report_too_large'); }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  const out = new Uint8Array(size); let offset = 0;
  for (const chunk of chunks) { out.set(chunk, offset); offset += chunk.length; }
  return new TextDecoder('utf-8', {fatal:true}).decode(out);
}
export function validateReport(data) {
  if (!data || typeof data !== 'object' || Array.isArray(data)) fail(400, 'invalid_report');
  const allowed = new Set(['title','body','app_version','os_version','provider','screenshot_png',
    'auth_code','code_verifier','publish_consent']);
  if (Object.keys(data).some(key => !allowed.has(key))) fail(400, 'invalid_report');
  for (const [key, max] of [['title',120],['body',8000],['app_version',80],['os_version',80]]) {
    if (typeof data[key] !== 'string' || !data[key].trim() || data[key].length > max ||
        /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/.test(data[key])) fail(400, 'invalid_report');
  }
  if (!PROVIDERS.includes(data.provider) || !VERIFIER.test(data.code_verifier || '')) fail(400, 'invalid_report');
  if (data.provider === 'github' && data.publish_consent !== true) fail(400, 'public_consent_required');
  if (data.screenshot_png !== undefined) validatePNG(data.screenshot_png);
  return Object.fromEntries(['title','body','app_version','os_version','provider','publish_consent','screenshot_png']
    .filter(key => data[key] !== undefined).map(key => [key, data[key]]));
}
// Validate complete PNG structure and CRCs; bound decompressed dimensions before storage/delivery.
export function validatePNG(base64) {
  if (typeof base64 !== 'string' || base64.length > 2796204 || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(base64)) fail(400, 'invalid_image');
  const raw = Uint8Array.from(atob(base64), c => c.charCodeAt(0));
  if (raw.length > 2 * 1024 * 1024 || raw.length < 57 ||
      ![137,80,78,71,13,10,26,10].every((v,i) => raw[i] === v)) fail(400, 'invalid_image');
  const view = new DataView(raw.buffer); let p = 8, header = false, data = false;
  while (p + 12 <= raw.length) {
    const n = view.getUint32(p); if (n > raw.length - p - 12) fail(400, 'invalid_image');
    const type = String.fromCharCode(...raw.slice(p+4,p+8));
    let crc = 0xffffffff;
    for (let i=p+4;i<p+8+n;i++) { crc ^= raw[i]; for(let b=0;b<8;b++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0); }
    if (((crc ^ 0xffffffff) >>> 0) !== view.getUint32(p+8+n)) fail(400, 'invalid_image');
    if (!header && type !== 'IHDR') fail(400, 'invalid_image');
    if (type === 'IHDR') {
      if (header || n !== 13) fail(400, 'invalid_image');
      const w=view.getUint32(p+8), h=view.getUint32(p+12);
      if (!w || !h || w>4096 || h>4096 || w*h>4194304) fail(400,'invalid_image');
      header=true;
    }
    if (type === 'acTL') fail(400, 'invalid_image');
    if (type === 'IDAT') data=true;
    if (type === 'IEND') {
      if (n || !data || p+12 !== raw.length) fail(400, 'invalid_image');
      return;
    }
    p += n + 12;
  }
  fail(400, 'invalid_image');
}
