// Picture-Line licence endpoint (Vercel Node function, no dependencies).
//
//   GET  /api/license?buy=USD|INR   create a Razorpay order, open Standard Checkout
//   POST /api/license               Checkout callback (razorpay_payment_id …) → redirect to the key page
//   GET  /api/license?id=pay_…      show the licence key for a captured payment (same key every time)
//
// Env: RZP_KEY_ID, RZP_KEY_SECRET, LICENSE_PRIVATE_KEY (Ed25519 PKCS8 PEM), REVOKED (comma list of payment IDs).
// Licence = base64url(JSON {email, payment_id, product, issued}) + "." + base64url(Ed25519 signature).
// The signature covers the base64url payload text, exactly as License.swift checks it.
'use strict';
const crypto = require('crypto');

const PRODUCT = 'picture-line';
const PRICES = { USD: { amount: 499, label: '$4.99' }, INR: { amount: 39900, label: '₹399' } };
const APP_PUBLIC_KEY = 'MM4elBoyLsaUFnSZmk7tDarmphbh5gV/w2KoYJJqrg4='; // the key compiled into License.swift
const SUPPORT = 'kjrlabs9@gmail.com';
const DMG = '/download/Picture-Line-1.0.dmg';
const PAY_ID = /^pay_[A-Za-z0-9]{14}$/;

const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const b64url = b => Buffer.from(b).toString('base64url');

function config() {
  const { RZP_KEY_ID: id, RZP_KEY_SECRET: secret, LICENSE_PRIVATE_KEY: pem } = process.env;
  return id && secret && pem ? { id, secret, pem: pem.replace(/\\n/g, '\n') } : null;
}
const revoked = () => new Set((process.env.REVOKED || '').split(',').map(s => s.trim()).filter(Boolean));

async function razorpay(cfg, method, path, body) {
  const r = await fetch('https://api.razorpay.com/v1' + path, {
    method,
    headers: { Authorization: 'Basic ' + Buffer.from(cfg.id + ':' + cfg.secret).toString('base64'), 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(9000),
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) {
    const e = new Error((j.error && j.error.description) || 'Razorpay HTTP ' + r.status);
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
    issued: new Date(pay.created_at * 1000).toISOString().slice(0, 10), // from the payment, so re-issues match
  }));
  return payload + '.' + b64url(sign(payload, pem));
}

// Looks a payment up and decides what to show for it.
async function lookup(cfg, id) {
  let pay;
  try { pay = await razorpay(cfg, 'GET', '/payments/' + id); }
  catch (e) { if (e.status === 400 || e.status === 404) return { state: 'missing' }; throw e; }
  if (revoked().has(pay.id) || pay.status === 'refunded') return { state: 'refunded', pay };
  if (pay.status === 'authorized' || pay.status === 'created') return { state: 'pending', pay };
  if (pay.status !== 'captured' || !pay.order_id) return { state: 'unpaid', pay };
  const order = await razorpay(cfg, 'GET', '/orders/' + pay.order_id);
  if (!order.notes || order.notes.product !== PRODUCT) return { state: 'other', pay };
  return { state: 'ok', pay, key: makeLicence(pay, cfg.pem) };
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

function checkout(res, cfg, origin, cur, order) {
  const nonce = crypto.randomBytes(16).toString('base64');
  const opts = {
    key: cfg.id, amount: order.amount, currency: order.currency, order_id: order.id,
    name: 'Picture-Line', description: 'One-time unlock · all future updates included', image: origin + '/img/icon-512.png',
    callback_url: origin + '/api/license', redirect: true, notes: { product: PRODUCT }, theme: { color: '#262e63' },
  };
  page(res, 200, {
    title: 'Checkout',
    nonce,
    // Razorpay Checkout loads its own frames and scripts, so this page keeps a light policy.
    csp: "object-src 'none'; base-uri 'none'; frame-ancestors 'none'",
    body: `<div class="buycard"><img src="/img/icon-180.png" width="88" height="88" alt="Picture-Line app icon">
<div><h1>Unlock Picture-Line</h1>
<ul class="ticks"><li>Up to 12 photos on your string</li><li>Diwali, Holi and Christmas decorations</li><li>Birthday glow and confetti</li><li>Every colour, frame and handwriting</li><li>Pay once. Every future update is included.</li></ul>
<p class="small">Your photos stay on your Mac. Picture-Line has no account and uploads nothing.</p></div></div>
<p class="lede" id="msg">Opening secure checkout by Razorpay…</p>
<div class="ctas"><button class="btn" id="pay" type="button">Pay ${esc(PRICES[cur].label)}</button>
<a class="btn ghost" href="/#pricing">Back to Picture-Line</a></div>
<p class="small">One payment, no subscription. Your licence key appears on the next page as soon as the payment goes through.${cur === 'INR' ? ' UPI, cards and netbanking are accepted.' : ''}</p>
<script src="https://checkout.razorpay.com/v1/checkout.js" nonce="${nonce}"></script>
<script nonce="${nonce}">
(function () {
  var o = ${JSON.stringify(opts).replace(/</g, '\\u003c')};
  var msg = document.getElementById('msg');
  o.modal = { ondismiss: function () { msg.textContent = 'Checkout closed. Nothing was charged. Press Pay to try again.'; } };
  function go() {
    if (!window.Razorpay) { msg.textContent = 'Checkout could not load. Check your connection or turn off content blockers for this page, then press Pay.'; return; }
    new window.Razorpay(o).open();
  }
  document.getElementById('pay').addEventListener('click', go);
  if (document.readyState === 'complete') go(); else window.addEventListener('load', go);
})();
</script>`,
  });
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

async function readForm(req) {
  if (req.body && typeof req.body === 'object' && !Buffer.isBuffer(req.body)) return req.body;
  let raw = typeof req.body === 'string' ? req.body : Buffer.isBuffer(req.body) ? req.body.toString() : '';
  if (!raw && req.readable !== false) {
    const chunks = [];
    for await (const c of req) { chunks.push(c); if (chunks.length > 64) break; }
    raw = Buffer.concat(chunks).toString();
  }
  return Object.fromEntries(new URLSearchParams(raw));
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
      body: `<h1>Confirming your payment</h1><p class="lede">Your payment was received and Razorpay is confirming it. This page refreshes by itself and your key will appear here, usually within a minute.</p>
<p>Payment ID: <strong>${esc(id)}</strong>. If you close this page, you can come back to it from the <a href="/key">find my key</a> page.</p>`,
    });
    case 'refunded': return note(res, 410, 'This payment was returned', 'There\'s no licence key for a returned payment. The free version of Picture-Line keeps working.',
      `<p class="small">Think this is a mistake? Write to <a href="mailto:${SUPPORT}">${SUPPORT}</a> with the payment ID.</p>`);
    case 'other': return note(res, 404, 'That payment isn\'t for Picture-Line', 'The payment ID exists, but it wasn\'t for the Picture-Line unlock.', tryAgain);
    case 'unpaid': return note(res, 402, 'That payment didn\'t complete', 'Razorpay says this payment wasn\'t completed, so no money was taken for it.',
      `<p><a class="btn" href="/#pricing">Try again</a></p>`);
    default: return note(res, 404, 'We couldn\'t find that payment', 'Check the payment ID in your Razorpay receipt email. It starts with pay_ followed by 14 letters and numbers.', tryAgain);
  }
}

module.exports = async (req, res) => {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  try {
    const url = new URL(req.url, 'https://local');
    const cfg = config();

    if (req.method === 'POST') {
      const f = await readForm(req);
      const id = String(f.razorpay_payment_id || '');
      if (PAY_ID.test(id)) return redirect(res, 303, '/api/license?id=' + id + '&new=1');
      const why = f['error[description]'] || (f.error && f.error.description) || '';
      return note(res, 400, 'The payment didn\'t go through',
        'Nothing was charged for the unlock. You can try again, or use a different payment method.',
        `${why ? `<p class="small">Razorpay said: ${esc(why)}</p>` : ''}<p><a class="btn" href="/#pricing">Try again</a></p>
<p class="small">If your bank shows a deduction, it's normally reversed automatically within a few days. If it isn't, write to <a href="mailto:${SUPPORT}">${SUPPORT}</a>.</p>`);
    }
    if (req.method === 'HEAD') { res.statusCode = 200; return res.end(); }
    if (req.method !== 'GET') { res.statusCode = 405; res.setHeader('Allow', 'GET, POST'); return res.end(); }

    const buy = url.searchParams.get('buy'), id = url.searchParams.get('id');
    if (buy !== null) {
      const cur = String(buy).toUpperCase();
      if (!PRICES[cur]) return redirect(res, 302, '/#pricing');
      if (!cfg) return soon(res);
      let order;
      try {
        order = await razorpay(cfg, 'POST', '/orders', {
          amount: PRICES[cur].amount, currency: cur, receipt: 'pl-' + Date.now(), notes: { product: PRODUCT },
        });
      } catch (e) {
        console.error('order failed', cur, e.message);
        return note(res, 502, 'Checkout couldn\'t start', 'Something went wrong while setting up the payment. Nothing was charged.',
          `<p><a class="btn" href="/api/license?buy=${esc(cur)}">Try again</a></p>
${cur === 'USD' ? '<p class="small">Paying from India? <a href="/api/license?buy=INR">Pay ₹399 with UPI or card</a> instead.</p>' : ''}
<p class="small">Still stuck? Write to <a href="mailto:${SUPPORT}">${SUPPORT}</a>.</p>`);
      }
      return checkout(res, cfg, originOf(req), cur, order);
    }
    if (id !== null) {
      if (!PAY_ID.test(id)) return note(res, 400, 'That doesn\'t look like a payment ID', 'Payment IDs start with pay_ followed by 14 letters and numbers, for example pay_AbCdEf12345678.', '<p><a class="btn" href="/key">Try again</a></p>');
      if (!cfg) return soon(res);
      return await showKey(res, cfg, id, url.searchParams.get('new') === '1');
    }
    return redirect(res, 302, '/#pricing');
  } catch (e) {
    console.error(e);
    return note(res, 500, 'Something went wrong on our side',
      'Your payment, if you made one, is safe. Reload this page in a minute, or get your key later from the find my key page using your payment ID.',
      `<p><a class="btn" href="/key">Find my key</a></p><p class="small">Or write to <a href="mailto:${SUPPORT}">${SUPPORT}</a>.</p>`);
  }
};
