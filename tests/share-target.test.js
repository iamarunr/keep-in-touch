const path = require('path'); const os = require('os');
const ROOT = path.resolve(__dirname, '..');
const OUT = path.join(__dirname, 'output'); require('fs').mkdirSync(OUT, { recursive: true });
const { chromium } = require('playwright'); const assert = require('assert');
const BASE = 'http://127.0.0.1:8766/';
// Android's share sheet POSTs the .vcf to the manifest's share_target action. There's no server,
// so the service worker has to catch it. Simulate the share with a real multipart form POST.
(async()=>{
  const b=await chromium.launch(); const ctx=await b.newContext({ viewport: { width: 412, height: 900 } }); const p=await ctx.newPage();
  const errs=[]; p.on('pageerror',e=>errs.push(e.message));
  await ctx.route(/fonts\.(googleapis|gstatic)\.com/, r => r.abort());

  const manifest=await (await ctx.request.get(BASE+'manifest.webmanifest')).json();
  const st=manifest.share_target;
  assert.equal(st.method,'POST'); assert.equal(st.enctype,'multipart/form-data');
  const field=st.params.files[0];
  assert.ok(field.accept.includes('text/vcard')&&field.accept.includes('.vcf'), 'accepts vCards');

  await p.goto(BASE+'#today'); await p.evaluate(()=>navigator.serviceWorker.ready); await p.reload(); await p.waitForTimeout(500);
  assert.ok(await p.evaluate(()=>!!navigator.serviceWorker.controller), 'service worker controls the page');

  await p.evaluate(({action,name})=>{
    const f=document.createElement('form'); f.method='POST'; f.enctype='multipart/form-data'; f.action=action; f.id='share';
    const i=document.createElement('input'); i.type='file'; i.name=name; f.append(i); document.body.append(f);
  },{action:st.action,name:field.name});
  await p.setInputFiles('#share input',path.join(__dirname,'fixtures','iphone-contact.vcf'));
  await Promise.all([p.waitForURL(/#import$/), p.evaluate(()=>document.getElementById('share').submit())]);
  const btn=p.locator('text=/^Import \\d+ (people|person)$/');
  await btn.waitFor({timeout:5000});
  console.log('after share, url:', p.url(), '| button:', await btn.textContent());
  assert.equal(await btn.textContent(),'Import 1 person');
  assert.match(await p.textContent('table.prev tbody'), /John Smith/);
  await p.screenshot({path:path.join(OUT,'share-target.png')});

  await btn.click(); await p.waitForURL(/#people$/); await p.waitForTimeout(800); await p.reload(); await p.waitForTimeout(600);
  const people=await p.locator('.prow').allTextContents();
  console.log('after import + reload, people:', people.length);
  assert.equal(people.length,1); assert.match(people[0],/John Smith/);

  // The shared file is used once: opening Import again doesn't bring the preview back.
  await p.goto(BASE+'#import'); await p.waitForTimeout(800);
  assert.equal(await p.locator('table.prev').count(),0, 'shared file consumed');

  console.log('ERRORS',errs); assert.deepEqual(errs,[]); await b.close();
})().catch(e=>{console.error(e);process.exit(1);});
