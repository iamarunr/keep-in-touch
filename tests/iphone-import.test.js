const path = require('path'); const os = require('os');
const ROOT = path.resolve(__dirname, '..');
const OUT = path.join(__dirname, 'output'); require('fs').mkdirSync(OUT, { recursive: true });
const { chromium, devices } = require('playwright');
(async()=>{
  const b=await chromium.launch(); const ctx=await b.newContext(devices['iPhone 15']); const p=await ctx.newPage();
  const errs=[]; p.on('pageerror',e=>errs.push(e.message));
  await ctx.route(/fonts\.(googleapis|gstatic)\.com/, r => r.abort());
  await p.goto('http://127.0.0.1:8766/#import'); await p.waitForTimeout(600);
  await p.setInputFiles('input[type=file][accept^=".csv"]',path.join(__dirname,'fixtures','iphone-contact.vcf')); await p.waitForTimeout(900);
  const btn=p.locator('text=/^Import \\d+ (people|person)$/');
  const box=await btn.boundingBox(); console.log('import button y on screen:', Math.round(box.y), 'of', p.viewportSize().height, '-> visible:', box.y>0&&box.y+box.height<p.viewportSize().height);
  await p.screenshot({path:path.join(OUT,'iphone-import.png')});
  await btn.click(); await p.waitForTimeout(800); await p.reload(); await p.waitForTimeout(600);
  console.log('after import + reload, people:', await p.locator('.prow').count());
  console.log('ERRORS',errs); await b.close();
})();
