const path = require('path'); const os = require('os');
const ROOT = path.resolve(__dirname, '..');
const OUT = path.join(__dirname, 'output'); require('fs').mkdirSync(OUT, { recursive: true });
const { chromium } = require('playwright');
const fs = require('fs');
const BASE = 'http://127.0.0.1:8766/';
const pickerMock = `
  window.ContactsManager = function(){};
  Object.defineProperty(navigator,'contacts',{value:{
    getProperties: async()=>['name','email','tel','address'],
    select: async(props,opts)=> opts.multiple
      ? [{name:['Ravi Kumar'],email:['ravi@x.com'],tel:['+1 555 0100'],address:[{city:'Carbondale'}]},{name:[],email:['noname@x.com'],tel:[]}]
      : [{name:['Laura Ortiz'],email:['laura@x.com'],tel:['+1 555 0199'],address:[]}]
  }});`;
(async () => {
  const b = await chromium.launch();
  const ctx = await b.newContext({ viewport: { width: 412, height: 900 }, acceptDownloads: true });
  await ctx.addInitScript(pickerMock);
  const p = await ctx.newPage();
  const errs = [];
  p.on('pageerror', e => errs.push('pageerror: ' + e.message));
  p.on('console', m => { if (m.type() === 'error' && !/fonts|ERR_/.test(m.text())) errs.push(m.text()); });
  await ctx.route(/fonts\.(googleapis|gstatic)\.com/, r => r.abort());

  await p.goto(BASE + '#add'); await p.waitForTimeout(400);
  // fill from phone
  await p.click('text=Fill from phone contacts'); await p.waitForTimeout(200);
  console.log('prefill name:', await p.inputValue('input[placeholder="Full name"]'), '| email:', await p.inputValue('input[type=email]'));
  await p.click('button[type=submit]'); await p.waitForTimeout(200);

  // import via picker
  await p.goto(BASE + '#import'); await p.waitForTimeout(300);
  await p.click('text=Choose contacts'); await p.waitForTimeout(200);
  console.log('preview rows:', await p.locator('table.prev tbody tr').count());
  await p.click('text=/^Import \\d+ (people|person)$/'); await p.waitForTimeout(800);
  console.log('people after import:', await p.locator('.prow').count());

  // persistence across reload
  await p.reload(); await p.waitForTimeout(500);
  await p.goto(BASE + '#people'); await p.waitForTimeout(400);
  console.log('people after reload:', await p.locator('.prow').count());

  // service worker + offline
  const swReady = await p.evaluate(async () => { const r = await navigator.serviceWorker.ready; return !!r.active; });
  console.log('service worker active:', swReady);
  await p.reload(); await p.waitForTimeout(300); // let SW control the page
  await ctx.setOffline(true);
  await p.goto(BASE + '#today'); await p.waitForTimeout(500);
  console.log('offline title:', await p.title(), '| stats present:', await p.locator('#stats .stat').count());
  await ctx.setOffline(false);

  // manifest
  const man = await p.evaluate(async () => (await fetch('manifest.webmanifest')).json());
  console.log('manifest icons:', man.icons.length, man.display, man.start_url);

  // backup download + restore into a fresh context
  await p.goto(BASE + '#prefs'); await p.waitForTimeout(300);
  const [dl] = await Promise.all([p.waitForEvent('download'), p.click('text=Download backup')]);
  const backupPath = path.join(os.tmpdir(), dl.suggestedFilename()); await dl.saveAs(backupPath);
  const backup = JSON.parse(fs.readFileSync(backupPath, 'utf8'));
  console.log('backup file:', dl.suggestedFilename(), 'contacts:', backup.contacts.length);
  await p.waitForTimeout(200);
  console.log('status line:', await p.textContent('.card .meta'));
  await p.screenshot({ path: path.join(OUT,'settings.png'), fullPage: true });

  const ctx2 = await b.newContext({ viewport: { width: 412, height: 900 } });
  const p2 = await ctx2.newPage(); p2.on('pageerror', e => errs.push('p2: ' + e.message));
  await p2.goto(BASE + '#prefs'); await p2.waitForTimeout(400);
  const fc = p2.waitForEvent('filechooser'); await p2.click('text=Restore from backup');
  await (await fc).setFiles(backupPath); await p2.waitForTimeout(200);
  await p2.click('.banner >> text=Restore'); await p2.waitForTimeout(600);
  await p2.goto(BASE + '#people'); await p2.waitForTimeout(400);
  console.log('restored people on fresh device:', await p2.locator('.prow').count());
  await p2.goto(BASE + '#import'); await p2.waitForTimeout(300);
  console.log('no-picker hint shown:', await p2.locator('text=/can’t open your phone’s contacts/').count());

  // two tabs stay in sync
  const t2 = await ctx.newPage(); await t2.goto(BASE + '#people'); await t2.waitForTimeout(400);
  await p.goto(BASE + '#add'); await p.waitForTimeout(300);
  await p.fill('input[placeholder="Full name"]', 'Tab Sync Test'); await p.click('button[type=submit]'); await p.waitForTimeout(500);
  console.log('other tab sees new person:', await t2.locator('text=Tab Sync Test').count());

  await p.goto(BASE + '#today'); await p.waitForTimeout(300);
  await p.screenshot({ path: path.join(OUT,'today.png'), fullPage: true });
  console.log('ERRORS', errs);
  await b.close();
})();
