const path = require('path'); const os = require('os');
const ROOT = path.resolve(__dirname, '..');
const OUT = path.join(__dirname, 'output'); require('fs').mkdirSync(OUT, { recursive: true });
const { chromium, devices } = require('playwright');
(async()=>{
  const b=await chromium.launch(); const errs=[];
  for (const [label,opts] of [['Pixel / Chrome',devices['Pixel 7']],['iPhone / Safari',devices['iPhone 15']],['Desktop Chrome',{}]]) {
    const ctx=await b.newContext(opts); const p=await ctx.newPage(); p.on('pageerror',e=>errs.push(e.message));
    await p.goto('http://127.0.0.1:8766/'); await p.waitForTimeout(600);
    const visible=await p.isVisible('#installBtn'); await p.click('#installBtn'); await p.waitForTimeout(150);
    console.log(label,'| button visible:',visible,'| help:',(await p.textContent('#installHelp')).trim());
    if(label==='Pixel / Chrome') await p.screenshot({path:path.join(OUT,'install-help.png')});
    await ctx.close();
  }
  // standalone: button hidden
  const ctx=await b.newContext(); await ctx.addInitScript(()=>{const o=window.matchMedia;window.matchMedia=q=>q.includes('standalone')?{matches:true,addEventListener(){},removeEventListener(){}}:o.call(window,q);});
  const p=await ctx.newPage(); await p.goto('http://127.0.0.1:8766/'); await p.waitForTimeout(400);
  console.log('installed app | button visible:', await p.isVisible('#installBtn'));
  console.log('ERRORS',errs); await b.close();
})();
