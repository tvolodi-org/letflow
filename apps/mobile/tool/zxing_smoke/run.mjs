// Runtime check of the self-hosted zxing-wasm (PWA M4, D-112: no CDN).
//
// For a root and a non-root base path it serves apps/mobile/web/ over local HTTP,
// opens a smoke page in headless Firefox that loads the two zxing script tags taken
// verbatim from web/index.html, decodes an EAN-13 drawn on a canvas through
// ZXingWASM.readBarcodes (the zxing fallback of mobile_scanner, so the WASM path is
// always used), and checks that every request stayed on the app's origin and base path.
//
// Node stdlib only. Exit 0 = pass, 1 = fail, 77 = skipped (node or firefox missing and
// env CI unset; with CI set a missing tool is a failure).
//
// Usage: node tool/zxing_smoke/run.mjs   (from apps/mobile)

import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const webDir = path.resolve(here, '..', '..', 'web');
const expected = '5901234123457';
const bases = ['/', '/sub/app/'];
const browserTimeoutMs = 60000;

function fail(message) {
  console.error(`zxing smoke: FAIL: ${message}`);
  process.exit(1);
}

function findFirefox() {
  const fromEnv = process.env.FIREFOX_BIN;
  if (fromEnv && fs.existsSync(fromEnv)) return fromEnv;
  const which = spawnSync('which', ['firefox'], { encoding: 'utf8' });
  const found = (which.stdout || '').trim();
  return which.status === 0 && found ? found : null;
}

function zxingTags() {
  const html = fs.readFileSync(path.join(webDir, 'index.html'), 'utf8');
  const bundle = html.match(/<script[^>]*id="mobile-scanner-zxing-wasm"[^>]*><\/script>/);
  const config = html.match(/<script[^>]*src="zxing\/zxing-config\.js"[^>]*><\/script>/);
  if (!bundle) fail('web/index.html has no script#mobile-scanner-zxing-wasm');
  if (!config) fail('web/index.html has no zxing/zxing-config.js script');
  return `${bundle[0]}\n${config[0]}`;
}

// The page draws EAN-13 5901234123457 (L/G/R patterns computed here, no binary fixture).
function smokePage(base, tags) {
  return `<!DOCTYPE html>
<html><head><meta charset="UTF-8"><base href="${base}"><link rel="icon" href="data:,">
${tags}
</head><body><canvas id="c"></canvas><script>
(async () => {
  const report = (body) => fetch('__report', { method: 'POST', body: JSON.stringify(body) });
  try {
    const L = ['0001101','0011001','0010011','0111101','0100011','0110001','0101111','0111011','0110111','0001011'];
    const R = L.map((p) => p.replace(/./g, (b) => (b === '0' ? '1' : '0')));
    const G = R.map((p) => p.split('').reverse().join(''));
    const parity = ['LLLLLL','LLGLGG','LLGGLG','LLGGGL','LGLLGG','LGGLLG','LGGGLL','LGLGLG','LGLGGL','LGGLGL'];
    const digits = '${expected}'.split('').map(Number);
    let bits = '101';
    for (let i = 1; i <= 6; i++) bits += (parity[digits[0]][i - 1] === 'L' ? L : G)[digits[i]];
    bits += '01010';
    for (let i = 7; i <= 12; i++) bits += R[digits[i]];
    bits += '101';
    const scale = 3, quiet = 12, height = 120;
    const canvas = document.getElementById('c');
    canvas.width = (bits.length + 2 * quiet) * scale;
    canvas.height = height + 2 * quiet * scale;
    const ctx = canvas.getContext('2d');
    ctx.fillStyle = '#fff';
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    ctx.fillStyle = '#000';
    for (let i = 0; i < bits.length; i++) {
      if (bits[i] === '1') ctx.fillRect((quiet + i) * scale, quiet * scale, scale, height);
    }
    const image = ctx.getImageData(0, 0, canvas.width, canvas.height);
    const results = await ZXingWASM.readBarcodes(image, { formats: ['EAN13'] });
    const decoded = results.length > 0 ? results[0].text : null;
    const resources = performance.getEntriesByType('resource').map((r) => r.name);
    await report({ decoded, resources });
  } catch (e) {
    await report({ error: String(e), resources: performance.getEntriesByType('resource').map((r) => r.name) });
  }
})();
</script></body></html>`;
}

const types = { '.js': 'text/javascript', '.wasm': 'application/wasm', '.html': 'text/html', '.json': 'application/json', '.png': 'image/png' };

function runOne(firefox, base, tags) {
  return new Promise((resolve) => {
    const seen = [];
    let browser = null;
    let timer = null;
    let profile = null;
    const finish = (result) => {
      if (timer) clearTimeout(timer);
      if (browser && browser.exitCode === null) {
        try { process.kill(-browser.pid, 'SIGKILL'); } catch { /* already gone */ }
      }
      server.close();
      if (profile) fs.rmSync(profile, { recursive: true, force: true });
      resolve({ ...result, seen });
    };
    const server = http.createServer((req, res) => {
      const url = new URL(req.url, 'http://127.0.0.1');
      seen.push(url.pathname);
      if (req.method === 'POST' && url.pathname === `${base}__report`) {
        let body = '';
        req.on('data', (chunk) => { body += chunk; });
        req.on('end', () => {
          res.end('ok');
          let parsed;
          try { parsed = JSON.parse(body); } catch { parsed = { error: `bad report ${body}` }; }
          finish(parsed);
        });
        return;
      }
      if (url.pathname === `${base}__smoke.html`) {
        res.writeHead(200, { 'content-type': 'text/html' });
        res.end(smokePage(base, tags));
        return;
      }
      if (!url.pathname.startsWith(base)) {
        res.writeHead(404);
        res.end();
        return;
      }
      const rel = decodeURIComponent(url.pathname.slice(base.length));
      const file = path.resolve(webDir, rel);
      if (!file.startsWith(webDir + path.sep) || !fs.existsSync(file) || !fs.statSync(file).isFile()) {
        res.writeHead(404);
        res.end();
        return;
      }
      res.writeHead(200, { 'content-type': types[path.extname(file)] || 'application/octet-stream' });
      fs.createReadStream(file).pipe(res);
    });
    server.listen(0, '127.0.0.1', () => {
      const port = server.address().port;
      profile = fs.mkdtempSync(path.join(os.tmpdir(), 'zxing-smoke-ff-'));
      const pageUrl = `http://127.0.0.1:${port}${base}__smoke.html`;
      browser = spawn(firefox, ['--headless', '--no-remote', '--profile', profile, pageUrl], {
        stdio: 'ignore',
        detached: true,
        env: { ...process.env, MOZ_CRASHREPORTER_DISABLE: '1' },
      });
      browser.on('error', (e) => finish({ error: `firefox did not start: ${e.message}` }));
      timer = setTimeout(() => finish({ error: `no report within ${browserTimeoutMs / 1000} s` }), browserTimeoutMs);
    });
  });
}

async function main() {
  const firefox = findFirefox();
  if (!firefox) {
    if (process.env.CI) fail('firefox is not installed (CI is set, so this is not skipped)');
    console.log('zxing smoke: SKIP: firefox not found');
    process.exit(77);
  }
  const tags = zxingTags();
  for (const base of bases) {
    const result = await runOne(firefox, base, tags);
    if (result.error) fail(`base ${base}: ${result.error}`);
    if (result.decoded !== expected) fail(`base ${base}: decoded ${JSON.stringify(result.decoded)}, expected ${expected}`);
    for (const need of ['zxing/zxing-reader.iife.js', 'zxing/zxing-config.js', 'zxing/zxing_reader.wasm']) {
      if (!result.seen.includes(`${base}${need}`)) {
        fail(`base ${base}: the server never served ${base}${need} (requests: ${result.seen.join(', ')})`);
      }
    }
    for (const p of result.seen) {
      if (!p.startsWith(base)) fail(`base ${base}: request outside the base path: ${p}`);
    }
    for (const name of result.resources || []) {
      const u = new URL(name);
      if (u.hostname !== '127.0.0.1' || !u.pathname.startsWith(base)) {
        fail(`base ${base}: resource not from the app origin and base: ${name}`);
      }
    }
    console.log(`zxing smoke: base ${base}: decoded ${result.decoded}; requests: ${result.seen.join(', ')}`);
  }
  console.log('zxing smoke: PASS');
}

main().catch((e) => fail(String(e && e.stack ? e.stack : e)));
