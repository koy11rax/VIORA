// Local visual QA only. Reads the approved HTML without modifying it.
const fs = require('fs');
const path = require('path');
const { chromium } = require(process.env.VIORA_PLAYWRIGHT_MODULE || 'playwright');
(async () => {
  const browser = await chromium.launch({ executablePath: process.env.VIORA_BROWSER_PATH, headless: true });
  const page = await browser.newPage({viewport: {width: 1280, height: 1000}, deviceScaleFactor: 1});
  const source = fs.readFileSync(path.join(__dirname, '../docs/approved-owner-concept.html'), 'utf8');
  await page.setContent('<html><meta charset="utf-8"><style>body{margin:0} .study-tools,.vi-title{display:none!important} .vi-app{border:0!important;border-radius:0!important}</style>' + source + '</html>');
  // Lucide is supplied by the conversation renderer; supply it for standalone QA.
  try { await page.addScriptTag({url:'https://unpkg.com/lucide@0.468.0/dist/umd/lucide.min.js'}); }
  catch (_) { /* Layout can still be reviewed if the icon CDN is unavailable. */ }
  await page.evaluate(() => { if (globalThis.lucide) lucide.createIcons(); });
  const dir = path.join(__dirname, '../artifacts');
  fs.mkdirSync(dir, {recursive:true});
  for (const screen of ['home', 'servers', 'appearance', 'settings']) {
    await page.locator(`.vi-desktop [data-nav="${screen}"]`).click();
    await page.locator('.vi-app').screenshot({path:path.join(dir, `reference-${screen}.png`)});
  }
  await browser.close();
})().catch(e => { console.error(e.message); process.exitCode = 1; });
