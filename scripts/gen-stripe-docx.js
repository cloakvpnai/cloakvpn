#!/usr/bin/env node
// Generator for docs/STRIPE_SETUP.docx — a professional Word version of
// docs/STRIPE_SETUP.md. Meant to be regenerated from the source markdown
// if either the .md or this script changes.
//
// Usage (from the docs/ dir or wherever; uses absolute output path):
//   node gen-stripe-docx.js

const fs = require('fs');
const path = require('path');
const {
  Document, Packer, Paragraph, TextRun, Table, TableRow, TableCell,
  Header, Footer, AlignmentType, PageOrientation, LevelFormat,
  ExternalHyperlink, HeadingLevel, BorderStyle, WidthType, ShadingType,
  PageNumber, PageBreak, TableOfContents, TabStopType, TabStopPosition,
} = require('docx');

// --- Palette ---------------------------------------------------------------
// Conservative, reads as professional/technical. Primary accent is a
// muted blue that evokes "VPN / security" without being loud.
const COL = {
  primary:   '1F3A5F',  // deep navy
  accent:    '2E75B6',  // muted blue
  codeFill:  'F2F2F2',  // light grey for inline code backing
  tableHead: 'D5E2EF',  // light blue for table header row
  border:    'CCCCCC',
  dim:       '666666',
};

// --- Helpers ---------------------------------------------------------------

function heading1(text) {
  return new Paragraph({
    heading: HeadingLevel.HEADING_1,
    children: [new TextRun({ text, color: COL.primary })],
  });
}

function heading2(text) {
  return new Paragraph({
    heading: HeadingLevel.HEADING_2,
    children: [new TextRun({ text, color: COL.primary })],
  });
}

function heading3(text) {
  return new Paragraph({
    heading: HeadingLevel.HEADING_3,
    children: [new TextRun({ text, color: COL.primary })],
  });
}

// body() takes rich content: plain strings, {b:"..."} for bold,
// {i:"..."} for italic, {code:"..."} for inline monospace, or
// {link:{text,url}} for hyperlinks.
function body(...parts) {
  const children = parts.map(p => {
    if (typeof p === 'string') return new TextRun(p);
    if (p.b) return new TextRun({ text: p.b, bold: true });
    if (p.i) return new TextRun({ text: p.i, italics: true });
    if (p.code) return new TextRun({
      text: p.code,
      font: 'Consolas',
      size: 20,                    // 10pt
      shading: { type: ShadingType.CLEAR, fill: COL.codeFill },
    });
    if (p.link) return new ExternalHyperlink({
      link: p.link.url,
      children: [new TextRun({ text: p.link.text, style: 'Hyperlink' })],
    });
    throw new Error('unknown body part: ' + JSON.stringify(p));
  });
  return new Paragraph({
    children,
    spacing: { before: 80, after: 80 },
  });
}

// codeBlock() renders a multi-line code snippet in Consolas with subtle
// grey background + left accent border. Each line is its own Paragraph
// so line breaks render correctly.
function codeBlock(text) {
  const lines = text.split('\n');
  return lines.map((line, idx) => new Paragraph({
    children: [new TextRun({
      text: line || ' ',                 // empty lines need a space to render
      font: 'Consolas',
      size: 20,                          // 10pt
    })],
    shading: { type: ShadingType.CLEAR, fill: COL.codeFill },
    spacing: {
      before: idx === 0 ? 120 : 0,
      after: idx === lines.length - 1 ? 120 : 0,
      line: 240,                         // tight line spacing
    },
    border: {
      left: { style: BorderStyle.SINGLE, size: 18, color: COL.accent, space: 6 },
    },
    indent: { left: 180 },
  }));
}

function bullet(text) {
  return new Paragraph({
    numbering: { reference: 'bullets', level: 0 },
    children: [new TextRun(text)],
    spacing: { before: 40, after: 40 },
  });
}

function numbered(text) {
  return new Paragraph({
    numbering: { reference: 'numbers', level: 0 },
    children: [new TextRun(text)],
    spacing: { before: 40, after: 40 },
  });
}

// --- Table helper ----------------------------------------------------------
// contentWidth = 12240 (US Letter) - 1440 - 1440 (1" margins) = 9360

const CONTENT_WIDTH = 9360;
const cellBorder = { style: BorderStyle.SINGLE, size: 4, color: COL.border };
const cellBorders = { top: cellBorder, bottom: cellBorder, left: cellBorder, right: cellBorder };

function dataCell(text, width, { bold=false, header=false, code=false } = {}) {
  return new TableCell({
    borders: cellBorders,
    width: { size: width, type: WidthType.DXA },
    shading: header
      ? { type: ShadingType.CLEAR, fill: COL.tableHead }
      : undefined,
    margins: { top: 80, bottom: 80, left: 120, right: 120 },
    children: [new Paragraph({
      children: [new TextRun({
        text,
        bold: bold || header,
        font: code ? 'Consolas' : 'Arial',
        size: code ? 18 : 20,            // 9pt code, 10pt normal
      })],
    })],
  });
}

function table(rows, widths) {
  return new Table({
    width: { size: CONTENT_WIDTH, type: WidthType.DXA },
    columnWidths: widths,
    rows: rows.map((row, rIdx) => new TableRow({
      children: row.map((cell, cIdx) => {
        const w = widths[cIdx];
        if (typeof cell === 'string') {
          return dataCell(cell, w, { header: rIdx === 0 });
        }
        return dataCell(cell.text, w, { header: rIdx === 0, ...cell });
      }),
    })),
  });
}

function spacer(after = 120) {
  return new Paragraph({ children: [new TextRun('')], spacing: { after } });
}

// --- Document content ------------------------------------------------------

const GENERATED = new Date().toISOString().slice(0, 10); // YYYY-MM-DD

const children = [];

// ---- Title block ----
children.push(new Paragraph({
  alignment: AlignmentType.CENTER,
  spacing: { before: 1440, after: 240 },
  children: [new TextRun({
    text: 'Cloak VPN',
    size: 52,                            // 26pt
    bold: true,
    color: COL.primary,
  })],
}));

children.push(new Paragraph({
  alignment: AlignmentType.CENTER,
  spacing: { after: 120 },
  children: [new TextRun({
    text: 'Stripe Setup Guide',
    size: 40,                            // 20pt
    color: COL.accent,
  })],
}));

children.push(new Paragraph({
  alignment: AlignmentType.CENTER,
  spacing: { after: 240 },
  children: [new TextRun({
    text: 'End-to-end walkthrough from zero to taking payments',
    italics: true,
    color: COL.dim,
  })],
}));

children.push(new Paragraph({
  alignment: AlignmentType.CENTER,
  spacing: { after: 480 },
  children: [new TextRun({
    text: `Generated ${GENERATED} · ~45 min read-through`,
    color: COL.dim,
    size: 20,
  })],
}));

// Divider
children.push(new Paragraph({
  border: { bottom: { style: BorderStyle.SINGLE, size: 6, color: COL.accent, space: 1 } },
  children: [new TextRun('')],
}));

children.push(new Paragraph({ children: [new PageBreak()] }));

// ---- TOC ----
children.push(heading1('Contents'));
children.push(new TableOfContents('Table of Contents', {
  hyperlink: true,
  headingStyleRange: '1-2',
}));
children.push(new Paragraph({ children: [new PageBreak()] }));

// ---- Section 0 ----
children.push(heading1('0. Why Payment Links instead of a custom checkout'));
children.push(body(
  'For the ~150-subscriber / $1k-MRR target we’re optimising for, Stripe Payment Links are the fastest path to revenue: zero frontend code, Stripe-hosted checkout page, and they work with the existing webhook handler out of the box. Every event a custom ',
  { code: 'Checkout Session' },
  ' would emit (',
  { code: 'checkout.session.completed' },
  ', ',
  { code: 'customer.subscription.updated' },
  ', ',
  { code: 'customer.subscription.deleted' },
  ') is also emitted by Payment Links — they are the same code path server-side.',
));
children.push(body(
  'If you later outgrow Payment Links (e.g. you want coupon codes, referral credits, or a custom checkout UI), the migration path is: add a ',
  { code: 'POST /v1/checkout' },
  ' endpoint that creates a ',
  { code: 'stripe.CheckoutSession' },
  ' and returns its URL. The webhook handler does not need to change.',
));

// ---- Section 1 ----
children.push(heading1('1. Pin the API version to 2025-03-30'));
children.push(body(
  { b: 'This is the single most important dashboard-side setting.' },
  ' Skip it and your yearly subscribers will silently deactivate 35 days into their year.',
));
children.push(body(
  'Stripe’s ',
  { code: '2025-03-31' },
  ' API version (codename “Basil”) moved ',
  { code: 'current_period_end' },
  ' off the ',
  { code: 'Subscription' },
  ' object and onto ',
  { code: 'SubscriptionItem' },
  '. Our Go SDK (',
  { code: 'stripe-go/v79' },
  ') predates that change and does not expose the new field as a typed struct. The webhook handler has a defensive fallback (',
  { code: 'itemPeriodEnd' },
  ' in ',
  { code: 'webhook.go' },
  ') that reaches into the raw JSON, but pinning the account-wide API version to pre-Basil is simpler and more reliable.',
));
children.push(heading3('To pin:'));
children.push(numbered('Stripe Dashboard → Developers → API version'));
children.push(numbered('You will see your current default version at the top'));
children.push(numbered('If it shows 2025-03-31 or later, click the dropdown and select 2025-03-30 — the last version that populates subscription.current_period_end'));
children.push(numbered('Save'));
children.push(body('This affects both API calls ', { i: 'and' }, ' webhook event payloads. Stripe backports this version for years, so there is no urgency to migrate.'));

// ---- Section 2 ----
children.push(heading1('2. Create the four products'));
children.push(body(
  'Create one Stripe ',
  { b: 'Product' },
  ' per pricing tier, with two recurring ',
  { b: 'Prices' },
  ' each (monthly + yearly). Dashboard → Product catalog → Create product. Repeat four times:',
));
children.push(spacer(80));
children.push(table(
  [
    ['Product name', 'Price', 'Interval', 'Notes'],
    ['Cloak VPN Basic', '$4.99', 'Monthly', '3 devices, EU+US core'],
    ['Cloak VPN Basic', '$49.99', 'Yearly', 'Same as above, yearly billing'],
    ['Cloak VPN Pro', '$9.99', 'Monthly', '10 devices, all locations'],
    ['Cloak VPN Pro', '$99.99', 'Yearly', 'Same, yearly billing'],
  ],
  [2400, 1200, 1500, 4260],
));
children.push(spacer(160));
children.push(body(
  'Matches ',
  { code: 'docs/PRICING.md' },
  '. AI Shield is currently deferred per the revenue-focused roadmap.',
));
children.push(body(
  { b: 'After each price is created, copy its price_... ID.' },
  ' You will need all four in section 5.',
));

// ---- Section 3 ----
children.push(heading1('3. Generate Payment Links'));
children.push(body('For each of the four prices:'));
children.push(numbered('Open the price in the dashboard'));
children.push(numbered('Click Create payment link'));
children.push(numbered('Under Options, enable Collect customer email (required — the webhook uses it as the account primary key)'));
children.push(numbered('Allow promotion codes: optional'));
children.push(numbered('Confirmation behaviour: redirect to https://cloakvpn.ai/welcome?session_id={CHECKOUT_SESSION_ID} (build this page later; for now redirect to cloakvpn.ai)'));
children.push(numbered('Click Create link → copy the https://buy.stripe.com/... URL'));
children.push(numbered('Paste it into the cloakvpn.ai Subscribe button for that tier'));

// ---- Section 4 ----
children.push(heading1('4. Create the webhook endpoint'));
children.push(body('Dashboard → Developers → Webhooks → Add endpoint:'));
children.push(bullet('Endpoint URL: https://api.cloakvpn.ai/v1/webhook/stripe'));
children.push(bullet('For now you can use ngrok against cloak-fi1 until the api. DNS is wired (run ngrok http 8080 on the box)'));
children.push(bullet('API version: default (which is 2025-03-30 after section 1)'));
children.push(body('Events to send — select exactly these three:'));
children.push(bullet('checkout.session.completed'));
children.push(bullet('customer.subscription.updated'));
children.push(bullet('customer.subscription.deleted'));
children.push(body(
  'Click Add endpoint. On the next page you will see a ',
  { b: 'Signing secret' },
  ' (',
  { code: 'whsec_...' },
  '). Copy it — this is ',
  { code: 'STRIPE_WEBHOOK_SECRET' },
  ' in section 5.',
));

// ---- Section 5 ----
children.push(heading1('5. Configure environment variables on the concentrator'));
children.push(body(
  'The API process (',
  { code: 'cloakvpn-api' },
  ') reads these from env. On cloak-fi1 we put them in ',
  { code: '/etc/cloakvpn/api.env' },
  ' and load via the systemd unit.',
));
children.push(...codeBlock(
`# /etc/cloakvpn/api.env — owned by root, 0600
LISTEN_ADDR=127.0.0.1:8080
DB_PATH=/var/lib/cloakvpn/cloakvpn.db

STRIPE_WEBHOOK_SECRET=whsec_...                  # from section 4
STRIPE_PRICE_BASIC_MONTH=price_...               # from section 2
STRIPE_PRICE_BASIC_YEAR=price_...
STRIPE_PRICE_PRO_MONTH=price_...
STRIPE_PRICE_PRO_YEAR=price_...

WG_IFACE=wg0
WG_SERVER_PUB=<from /etc/wireguard/server.pub>
WG_ENDPOINT=fi1.cloakvpn.ai:51820
WG_DNS=10.99.0.1
WG_ALLOWED_IPS=0.0.0.0/0, ::/0
WG_SUBNET=10.99.0.0/24`
));
children.push(body(
  { b: 'Security note:' },
  ' the file should be ',
  { code: 'chmod 600 /etc/cloakvpn/api.env' },
  ', owned by root. The webhook secret is the difference between “my API is secure” and “anyone can mint active subscriptions.”',
));

// ---- Section 6 ----
children.push(heading1('6. Test the flow end-to-end with Stripe CLI'));
children.push(body('Before pointing the real Payment Link at the live endpoint, dry-run it. On your laptop:'));
children.push(...codeBlock(
`# Install if you don't have it
brew install stripe/stripe-cli/stripe

# Login
stripe login

# Forward events to the running API (locally or via SSH tunnel to fi1)
stripe listen --forward-to http://localhost:8080/v1/webhook/stripe

# In another terminal, trigger a fake event
stripe trigger checkout.session.completed`
));
children.push(body(
  'You should see the forwarded event hit your API and log a line like ',
  { code: 'POST /v1/webhook/stripe 200 OK' },
  '. If you see signature-verify failures, the ',
  { code: 'STRIPE_WEBHOOK_SECRET' },
  ' env is not being picked up — ',
  { code: 'stripe listen' },
  ' prints its own test secret, which is ',
  { i: 'different' },
  ' from the one in the dashboard. Use ',
  { code: '--skip-verify' },
  ' for CLI testing OR set ',
  { code: 'STRIPE_WEBHOOK_SECRET' },
  ' to the ',
  { code: 'whsec_...' },
  ' the CLI prints on startup.',
));

// ---- Section 7 ----
children.push(heading1('7. Go live (test-mode first)'));
children.push(numbered('Flip the dashboard from Test mode to Live mode only when you are ready to take real money'));
children.push(numbered('Re-do sections 2, 3, 4 in live mode — products, payment links, and webhook endpoints are scoped per-mode'));
children.push(numbered('Update /etc/cloakvpn/api.env with the live whsec_... and live price_... IDs (prefixed price_1Live... vs price_1Test...)'));
children.push(numbered('Restart cloakvpn-api.service'));
children.push(numbered('Buy a subscription yourself with a real card to prove the full path works before telling anyone it is open'));

// ---- Section 8 ----
children.push(heading1('8. What happens when someone subscribes'));
children.push(body('The flow that makes all of this actually work:'));
children.push(numbered('User clicks Subscribe on cloakvpn.ai → redirected to https://buy.stripe.com/...'));
children.push(numbered('User enters email + card, pays'));
children.push(numbered('Stripe sends checkout.session.completed → our webhook'));
children.push(numbered('Our webhook calls UpsertAccountByStripeCustomer, creating the account row with tier, device_limit, active_until = now + 35d'));
children.push(numbered('User is redirected to cloakvpn.ai/welcome?session_id=cs_... where the page instructs them to open the Cloak app and sign in with the email they paid with'));
children.push(numbered('The Cloak app calls POST /v1/device with that email → server checks the account is active → wg.Controller.Provision mints WG + Rosenpass keys, adds the peer, returns the config → app imports it into the TunnelManager'));
children.push(numbered('Monthly / yearly renewal: Stripe charges the card → emits customer.subscription.updated → webhook refreshes active_until to the new period end + 3 days grace'));
children.push(numbered('Cancellation: Stripe emits customer.subscription.deleted → webhook deactivates the account → on next app call /v1/device returns 402 Payment Required'));

// ---- Section 9 ----
children.push(heading1('9. Troubleshooting'));

children.push(heading3('Webhook retries'));
children.push(body(
  'Stripe retries 4xx/5xx responses for up to 3 days. If you are debugging locally, check Dashboard → Developers → Webhooks → your endpoint → Event deliveries for the raw payload of failed events.',
));

children.push(heading3('Yearly subscribers expire at 35 days'));
children.push(body(
  'You forgot section 1 (pin API version). Fix it, then manually run:',
));
children.push(...codeBlock(
  `UPDATE accounts
     SET active_until = datetime('now', '+400 days')
   WHERE stripe_customer_id = 'cus_...';`,
));
children.push(body('to restore affected customers. Future updates will then refresh correctly.'));

children.push(heading3('New checkout emits checkout.session.completed but no account is created'));
children.push(body(
  'The ',
  { code: 'price_...' },
  ' in the event does not match any of the four env vars. Check the log for ',
  { code: '"checkout completed for unknown price %q"' },
  ' and reconcile.',
));

// --- Build + save ----------------------------------------------------------

const doc = new Document({
  creator: 'Cloak VPN',
  title: 'Cloak VPN — Stripe Setup Guide',
  styles: {
    default: {
      document: { run: { font: 'Arial', size: 22 } },   // 11pt body
    },
    paragraphStyles: [
      { id: 'Heading1', name: 'Heading 1', basedOn: 'Normal', next: 'Normal', quickFormat: true,
        run: { size: 32, bold: true, font: 'Arial', color: COL.primary },
        paragraph: { spacing: { before: 360, after: 180 }, outlineLevel: 0 } },
      { id: 'Heading2', name: 'Heading 2', basedOn: 'Normal', next: 'Normal', quickFormat: true,
        run: { size: 28, bold: true, font: 'Arial', color: COL.primary },
        paragraph: { spacing: { before: 240, after: 140 }, outlineLevel: 1 } },
      { id: 'Heading3', name: 'Heading 3', basedOn: 'Normal', next: 'Normal', quickFormat: true,
        run: { size: 24, bold: true, font: 'Arial', color: COL.accent },
        paragraph: { spacing: { before: 180, after: 100 }, outlineLevel: 2 } },
      { id: 'Hyperlink', name: 'Hyperlink', basedOn: 'Normal',
        run: { color: COL.accent, underline: {} } },
    ],
  },
  numbering: {
    config: [
      { reference: 'bullets',
        levels: [{ level: 0, format: LevelFormat.BULLET, text: '•',
          alignment: AlignmentType.LEFT,
          style: { paragraph: { indent: { left: 540, hanging: 260 } } } }] },
      { reference: 'numbers',
        levels: [{ level: 0, format: LevelFormat.DECIMAL, text: '%1.',
          alignment: AlignmentType.LEFT,
          style: { paragraph: { indent: { left: 540, hanging: 340 } } } }] },
    ],
  },
  sections: [{
    properties: {
      page: {
        size: { width: 12240, height: 15840 },       // US Letter
        margin: { top: 1440, right: 1440, bottom: 1440, left: 1440 },
      },
    },
    headers: {
      default: new Header({
        children: [new Paragraph({
          alignment: AlignmentType.RIGHT,
          children: [new TextRun({
            text: 'Cloak VPN — Stripe Setup Guide',
            size: 18,
            color: COL.dim,
          })],
        })],
      }),
    },
    footers: {
      default: new Footer({
        children: [new Paragraph({
          tabStops: [{ type: TabStopType.RIGHT, position: TabStopPosition.MAX }],
          children: [
            new TextRun({ text: `Generated ${GENERATED}`, color: COL.dim, size: 18 }),
            new TextRun({ text: '\tPage ', color: COL.dim, size: 18 }),
            new TextRun({ children: [PageNumber.CURRENT], color: COL.dim, size: 18 }),
          ],
        })],
      }),
    },
    children,
  }],
});

const outPath = process.argv[2] || path.join(__dirname, 'STRIPE_SETUP.docx');
Packer.toBuffer(doc).then(buf => {
  fs.writeFileSync(outPath, buf);
  console.log(`wrote ${outPath} (${(buf.length / 1024).toFixed(1)} KB)`);
});
