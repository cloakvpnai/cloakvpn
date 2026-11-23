// Builds the passphrase-protected roadmap page.
//
// The site and this repository are public, so the roadmap is never stored in
// either as readable text. This script encrypts the tracker with AES-256-GCM
// under a key derived from a passphrase (PBKDF2-HMAC-SHA-384, 600,000
// rounds) and writes public/roadmap/index.html, which holds only ciphertext
// and the code that decrypts it in the visitor's browser.
//
//   ROADMAP_PASSPHRASE=... node scripts/build-roadmap.mjs <tracker.html> [out.html]
import { createCipheriv, pbkdf2Sync, randomBytes } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ITERATIONS = 600000;
const pass = process.env.ROADMAP_PASSPHRASE || '';
const source = process.argv[2];
if (!source) { console.error('usage: build-roadmap.mjs <tracker.html> [out.html]'); process.exit(2); }
if (pass.length < 16) { console.error('Passphrase missing or shorter than 16 characters; refusing to publish.'); process.exit(1); }

const out = process.argv[3] || resolve(dirname(fileURLToPath(import.meta.url)), '../public/roadmap/index.html');
const salt = randomBytes(16), iv = randomBytes(12);
const key = pbkdf2Sync(pass, salt, ITERATIONS, 32, 'sha384');
const cipher = createCipheriv('aes-256-gcm', key, iv);
const sealed = Buffer.concat([cipher.update(readFileSync(source)), cipher.final(), cipher.getAuthTag()]);
const payload = JSON.stringify({ v: 1, kdf: 'PBKDF2-SHA-384', iterations: ITERATIONS, salt: salt.toString('base64'), iv: iv.toString('base64'), data: sealed.toString('base64') });

const page = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow, noarchive">
<title>Lattice VPN Roadmap</title>
<style>
:root{--bg:#F3F5FA;--surface:#FFFFFF;--ink:#0A1C3A;--muted:#51607A;--line:#D5DBE8;--navy:#0B2A5B;--err:#9C1F1F}
*{box-sizing:border-box}
body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:var(--bg);color:var(--ink);font-family:-apple-system,'Segoe UI',system-ui,sans-serif;padding:20px}
form{background:var(--surface);border:1px solid var(--line);border-top:4px solid var(--navy);border-radius:14px;padding:28px;max-width:420px;width:100%;display:flex;flex-direction:column;gap:14px}
h1{font-size:20px;margin:0;color:var(--navy)}
p{margin:0;color:var(--muted);font-size:14px;line-height:1.5}
label{font-size:13px;font-weight:600}
input{font:inherit;padding:12px;border:1px solid var(--line);border-radius:8px;width:100%}
button{font:inherit;font-weight:600;padding:12px;border:0;border-radius:8px;background:var(--navy);color:#fff;cursor:pointer;min-height:44px}
input:focus-visible,button:focus-visible{outline:3px solid var(--navy);outline-offset:2px}
#msg{color:var(--err);min-height:20px;font-size:14px}
</style>
</head>
<body>
<form id="f" autocomplete="off">
  <h1>Lattice VPN Roadmap</h1>
  <p>Internal page. Enter the passphrase to open it. The page is decrypted on this device; the passphrase is not sent anywhere.</p>
  <label for="p">Passphrase</label>
  <input id="p" type="password" autofocus required>
  <button type="submit" id="b">Open</button>
  <div id="msg" role="alert"></div>
</form>
<script id="sealed" type="application/json">${payload}</script>
<script>
(function () {
  var sealed = JSON.parse(document.getElementById('sealed').textContent);
  function bytes(b64) { return Uint8Array.from(atob(b64), function (c) { return c.charCodeAt(0); }); }
  document.getElementById('f').addEventListener('submit', async function (e) {
    e.preventDefault();
    var msg = document.getElementById('msg'), btn = document.getElementById('b');
    msg.textContent = ''; btn.disabled = true; btn.textContent = 'Opening';
    try {
      var material = await crypto.subtle.importKey('raw', new TextEncoder().encode(document.getElementById('p').value), 'PBKDF2', false, ['deriveKey']);
      var key = await crypto.subtle.deriveKey({ name: 'PBKDF2', salt: bytes(sealed.salt), iterations: sealed.iterations, hash: 'SHA-384' }, material, { name: 'AES-GCM', length: 256 }, false, ['decrypt']);
      var plain = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: bytes(sealed.iv) }, key, bytes(sealed.data));
      var html = new TextDecoder().decode(plain);
      document.open(); document.write(html); document.close();
    } catch (err) {
      msg.textContent = 'That passphrase did not open the page.';
      btn.disabled = false; btn.textContent = 'Open';
    }
  });
})();
</script>
</body>
</html>
`;
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, page);
console.log('wrote ' + out + ' (' + page.length + ' bytes, ' + sealed.length + ' encrypted)');
