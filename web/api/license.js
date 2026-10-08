// Picture-Line licence endpoint (Vercel Node function, no dependencies).
//
//   GET /api/license?buy                      create a Dodo Payments checkout session and send the buyer to it
//   GET /api/license?payment_id=pay_…&status  Dodo's return URL → the licence key page
//   GET /api/license?id=pay_…                 show the licence key for a paid payment (same key every time)
//
// Env: DODO_API_KEY, DODO_PRODUCT_ID (one product: $4.99, with a Localized Pricing rule India = ₹399), DODO_MODE (live|test, default live),
//      LICENSE_PRIVATE_KEY (Ed25519 PKCS8 PEM), REVOKED (comma list of payment IDs).
// Licence = base64url(JSON {email, payment_id, product, issued}) + "." + base64url(Ed25519 signature).
// The signature covers the base64url payload text, exactly as License.swift checks it.
'use strict';
const crypto = require('crypto');

const PRODUCT = 'picture-line';
const APP_PUBLIC_KEY = 'MM4elBoyLsaUFnSZmk7tDarmphbh5gV/w2KoYJJqrg4='; // the key compiled into License.swift
const SUPPORT = 'kjrlabs9@gmail.com';
const DMG = '/download/Picture-Line-1.0.dmg';
const PAY_ID = /^pay_[A-Za-z0-9]{8,40}$/;

const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const b64url = b => Buffer.from(b).toString('base64url');

function config() {
  const { DODO_API_KEY: key, DODO_PRODUCT_ID: product, DODO_MODE: mode, LICENSE_PRIVATE_KEY: pem } = process.env;
  if (!key || !product || !pem) return null;
  return {
    key, pem: pem.replace(/\\n/g, '\n'),
    product,
    base: mode === 'test' ? 'https://test.dodopayments.com' : 'https://live.dodopayments.com',
  };
}
const revoked = () => new Set((process.env.REVOKED || '').split(',').map(s => s.trim()).filter(Boolean));

async function dodo(cfg, method, path, body) {
  const r = await fetch(cfg.base + path, {
    method,
    headers: { Authorization: 'Bearer ' + cfg.key, 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(9000),
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) {
    const e = new Error(j.message || j.code || 'Dodo HTTP ' + r.status);
    e.status = r.status;
    throw e;
  }
  return j;
}

let signingKey;
function sign(payload, pem) {
  if (!signingKey) {
    const k = crypto.createPrivateKey(pem);
    const raw = crypto.createPublicKey(k).export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64');
    if (raw !== APP_PUBLIC_KEY) throw new Error('LICENSE_PRIVATE_KEY does not match the public key in the app');
    signingKey = k;
  }
  return crypto.sign(null, Buffer.from(payload), signingKey);
}

function makeLicence(pay, pem) {
  const payload = b64url(JSON.stringify({
    email: pay.email || null,
    payment_id: pay.id,
    product: PRODUCT,
    issued: pay.issued, // from the payment, so re-issues match
  }));
  return payload + '.' + b64url(sign(payload, pem));
}

// Looks a payment up and decides what to show for it.
async function lookup(cfg, id) {
  let p;
  try { p = await dodo(cfg, 'GET', '/payments/' + encodeURIComponent(id)); }
  catch (e) { if (e.status === 400 || e.status === 404) return { state: 'missing' }; throw e; }
  const pay = { id: p.payment_id || id, email: (p.customer && p.customer.email) || null, issued: String(p.created_at || '').slice(0, 10) };
  if (revoked().has(pay.id) || (p.refunds && p.refunds.length)) return { state: 'refunded', pay };
  const ours = (p.metadata && p.metadata.product === PRODUCT) ||
    (p.product_cart || []).some(i => i.product_id === cfg.product);
  if (!ours) return { state: 'other', pay };
  if (p.status === 'succeeded') return { state: 'ok', pay, key: makeLicence(pay, cfg.pem) };
  if (['processing', 'requires_customer_action', 'requires_merchant_action', 'requires_capture', 'requires_confirmation'].includes(p.status)) return { state: 'pending', pay };
  return { state: 'unpaid', pay };
}

// ---------- pages ----------
function page(res, status, { title, body, nonce, refresh, csp }) {
  res.statusCode = status;
  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('X-Robots-Tag', 'noindex');
  res.setHeader('Referrer-Policy', 'no-referrer');
  res.setHeader('Content-Security-Policy', csp || [
    "default-src 'none'", `script-src ${nonce ? `'nonce-${nonce}'` : "'none'"}`, "style-src 'self' https://fonts.googleapis.com",
    "font-src https://fonts.gstatic.com", "img-src 'self'", "form-action 'self'", "base-uri 'none'", "frame-ancestors 'none'",
  ].join('; '));
  res.end(`<!doctype html>
<html lang="en-GB">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
${refresh ? `<meta http-equiv="refresh" content="${refresh}">` : ''}
<title>${esc(title)} | Picture-Line</title>
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Instrument+Serif:ital@0;1&amp;family=Figtree:wght@400;500;600;700&amp;family=Kalam&amp;display=swap">
<link rel="stylesheet" href="/css/site.css?v=2">
<link rel="icon" href="/favicon.ico" sizes="32x32">
</head>
<body>
<header class="top"><div class="wrap"><a class="brand" href="/"><img src="/img/logo-64.png" width="32" height="32" alt="">Picture-Line</a></div></header>
<main id="main" class="page"><div class="wrap">
${body}
</div></main>
<footer class="foot"><div class="wrap"><div><p>Questions about a payment? Write to <a href="mailto:${SUPPORT}">${SUPPORT}</a>.</p>
<p><a href="/refunds">Cancellations</a> · <a href="/privacy">Privacy</a> · <a href="/terms">Terms</a></p></div></div></footer>
</body>
</html>`);
}

const note = (res, status, title, lede, extra = '') => page(res, status, {
  title, body: `<h1>${esc(title)}</h1>\n<p class="lede">${lede}</p>\n${extra}`,
});

function soon(res) {
  note(res, 200, 'Payments open very soon',
    'The unlock isn\'t on sale just yet. The free version is ready now and holds up to five photos.',
    `<p><a class="btn" href="${DMG}">Download free for Mac</a></p>
<p class="small">Want to hear when the unlock opens? Write to <a href="mailto:${SUPPORT}?subject=Picture-Line%20unlock">${SUPPORT}</a> or follow <a href="https://x.com/kshitijkoranne">@kshitijkoranne</a> on X.</p>`);
}

function thanks(res, pay, key, fresh) {
  const nonce = crypto.randomBytes(16).toString('base64');
  const open = 'picture-line://activate?key=' + encodeURIComponent(key);
  const mail = `mailto:${encodeURIComponent(pay.email || '')}?subject=${encodeURIComponent('My Picture-Line licence key')}&body=${encodeURIComponent(
    `Picture-Line licence key:\n\n${key}\n\nPayment ID: ${pay.id}\n\nTo activate: open Picture-Line, go to Settings > About, click Unlock…, then Have a licence key?, paste the key and click Activate.\nLost it again? https://picture-line.kjrlabs.in/key`)}`;
  page(res, 200, {
    title: fresh ? 'Thank you' : 'Your licence key',
    nonce,
    body: `<h1>${fresh ? 'Thank you. The unlock is yours.' : 'Here\'s your licence key.'}</h1>
<p class="lede">${fresh ? 'Your payment went through. ' : ''}Click the button below on the Mac where Picture-Line is installed, and it unlocks straight away.</p>
<p><a class="btn big" href="${esc(open)}">Open in Picture-Line</a></p>
<h2>Your licence key</h2>
<div class="keybox"><textarea id="key" readonly rows="4" spellcheck="false" aria-label="Licence key">${esc(key)}</textarea>
<div class="ctas"><button class="btn sm" id="copy" type="button">Copy</button><a class="btn sm ghost" href="${esc(mail)}">Email the key to myself</a><span id="copied" class="small" role="status"></span></div></div>
<p>Payment ID: <strong>${esc(pay.id)}</strong>. Keep it somewhere safe. With it you can get this key again at any time on the <a href="/key">find my key</a> page.</p>
<h2>If the button didn't open the app</h2>
<ol>
<li>Open Picture-Line and go to Settings → About.</li>
<li>Click Unlock…, then Have a licence key?</li>
<li>Paste the key above and click Activate.</li>
</ol>
<p>Don't have the app on this Mac yet? <a href="${DMG}">Download Picture-Line</a>, open it, then come back to this page.</p>
<script nonce="${nonce}">
document.getElementById('copy').addEventListener('click', function () {
  var t = document.getElementById('key'), s = document.getElementById('copied');
  function done() { s.textContent = 'Copied.'; }
  if (navigator.clipboard) navigator.clipboard.writeText(t.value).then(done, function () { t.select(); document.execCommand('copy'); done(); });
  else { t.select(); document.execCommand('copy'); done(); }
});
</script>`,
  });
}

function originOf(req) {
  const h = String(req.headers['x-forwarded-host'] || req.headers.host || '').split(',')[0].trim();
  return 'https://' + (/^[a-z0-9.-]+(:\d+)?$/i.test(h) ? h : 'picture-line.kjrlabs.in');
}

function redirect(res, status, to) {
  res.statusCode = status;
  res.setHeader('Location', to);
  res.setHeader('Cache-Control', 'no-store');
  res.end();
}

async function showKey(res, cfg, id, fresh) {
  const r = await lookup(cfg, id);
  const tryAgain = `<p><a class="btn" href="/key">Try another payment ID</a></p>`;
  switch (r.state) {
    case 'ok': return thanks(res, r.pay, r.key, fresh);
    case 'pending': return page(res, 200, {
      title: 'Confirming your payment', refresh: 8,
      body: `<h1>Confirming your payment</h1><p class="lede">Your payment was received and is being confirmed. This page refreshes by itself and your key will appear here, usually within a minute.</p>
<p>Payment ID: <strong>${esc(id)}</strong>. If you close this page, you can come back to it from the <a href="/key">find my key</a> page.</p>`,
    });
    case 'refunded': return note(res, 410, 'This payment was returned', 'There\'s no licence key for a returned payment. The free version of Picture-Line keeps working.',
      `<p class="small">Think this is a mistake? Write to <a href="mailto:${SUPPORT}">${SUPPORT}</a> with the payment ID.</p>`);
    case 'other': return note(res, 404, 'That payment isn\'t for Picture-Line', 'The payment ID exists, but it wasn\'t for the Picture-Line unlock.', tryAgain);
    case 'unpaid': return note(res, 402, 'That payment didn\'t complete', 'This payment wasn\'t completed, so no money was taken for it.',
      `<p><a class="btn" href="/#price">Try again</a></p>`);
    default: return note(res, 404, 'We couldn\'t find that payment', 'Check the payment ID in your receipt email from Dodo Payments. It starts with pay_.', tryAgain);
  }
}

module.exports = async (req, res) => {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  try {
    const url = new URL(req.url, 'https://local');
    const cfg = config();
    if (req.method === 'HEAD') { res.statusCode = 200; return res.end(); }
    if (req.method !== 'GET') { res.statusCode = 405; res.setHeader('Allow', 'GET'); return res.end(); }

    const q = k => url.searchParams.get(k);
    const buy = q('buy'), back = q('payment_id'), id = q('id');
    if (buy !== null) {
      if (!cfg) return soon(res); // ?buy=USD and ?buy=INR both land here: Dodo prices India at ₹399 by the buyer's country
      let s;
      try {
        s = await dodo(cfg, 'POST', '/checkouts', {
          product_cart: [{ product_id: cfg.product, quantity: 1 }],
          return_url: originOf(req) + '/api/license',
          metadata: { product: PRODUCT },
        });
      } catch (e) {
        console.error('checkout failed', e.message);
        return note(res, 502, 'Checkout couldn\'t start', 'Something went wrong while setting up the payment. Nothing was charged.',
          `<p><a class="btn" href="/api/license?buy">Try again</a></p>
<p class="small">Still stuck? Write to <a href="mailto:${SUPPORT}">${SUPPORT}</a>.</p>`);
      }
      return redirect(res, 303, s.checkout_url);
    }
    if (back !== null) { // Dodo's return URL
      const st = q('status');
      if (PAY_ID.test(back) && st !== 'failed' && st !== 'cancelled') return redirect(res, 303, '/api/license?id=' + back + '&new=1');
      return note(res, 400, 'The payment didn\'t go through',
        'Nothing was charged for the unlock. You can try again, or use a different payment method.',
        `<p><a class="btn" href="/#price">Try again</a></p>
<p class="small">If your bank shows a deduction, it's normally reversed automatically within a few days. If it isn't, write to <a href="mailto:${SUPPORT}">${SUPPORT}</a>.</p>`);
    }
    if (id !== null) {
      if (!PAY_ID.test(id)) return note(res, 400, 'That doesn\'t look like a payment ID', 'Payment IDs start with pay_ followed by letters and numbers. You\'ll find it in your receipt email.', '<p><a class="btn" href="/key">Try again</a></p>');
      if (!cfg) return soon(res);
      return await showKey(res, cfg, id, q('new') === '1');
    }
    return redirect(res, 302, '/#price');
  } catch (e) {
    console.error(e);
    return note(res, 500, 'Something went wrong on our side',
      'Your payment, if you made one, is safe. Reload this page in a minute, or get your key later from the find my key page using your payment ID.',
      `<p><a class="btn" href="/key">Find my key</a></p><p class="small">Or write to <a href="mailto:${SUPPORT}">${SUPPORT}</a>.</p>`);
  }
};
