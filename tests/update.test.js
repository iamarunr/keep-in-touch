const path = require('path'); const os = require('os');
const ROOT = path.resolve(__dirname, '..');
const OUT = path.join(__dirname, 'output'); require('fs').mkdirSync(OUT, { recursive: true });
const { chromium } = require('playwright'); const fs=require('fs');
(async()=>{
  const b=await chromium.launch(); const ctx=await b.newContext(); const p=await ctx.newPage(); const errs=[]; p.on('pageerror',e=>errs.push(e.message));
  await ctx.route(/fonts\.(googleapis|gstatic)\.com/, r => r.abort());
  await p.goto('http://127.0.0.1:8766/#prefs'); await p.waitForTimeout(1200); await p.reload(); await p.waitForTimeout(800);
  console.log('before:', await p.textContent('#storageinfo'));
  // ship a "new version": bump SW cache name + app version on disk
  const sw=path.join(ROOT,'sw.js'), ix=path.join(ROOT,'index.html');
  const swO=fs.readFileSync(sw,'utf8'), ixO=fs.readFileSync(ix,'utf8');
  fs.writeFileSync(sw,swO.replace('kit-v5','kit-v6-test')); fs.writeFileSync(ix,ixO.replace('APP_VERSION="5"','APP_VERSION="6-test"'));
  let navs=0; p.on('framenavigated',f=>{if(f===p.mainFrame()) navs++;});
  await p.reload(); await p.waitForTimeout(2500);  // one open: should auto-reload into the new version
  console.log('after one open:', await p.textContent('#storageinfo'), '| page loads:', navs);
  fs.writeFileSync(sw,swO); fs.writeFileSync(ix,ixO);
  console.log('ERRORS',errs); await b.close();
})();
