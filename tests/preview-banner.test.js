// The banner warns that a Cloudflare preview address (<hash>.keep-in-touch-d58.pages.dev) has its own separate data.
// Tests run on 127.0.0.1, so each case pretends to be another host through window.KIT_TEST_HOST.
const { chromium } = require('playwright');
(async()=>{
  const b=await chromium.launch(); const errs=[]; let fails=0;
  const cases=[
    ['abc123.keep-in-touch-d58.pages.dev', true],
    ['ABC123.Keep-In-Touch-D58.pages.dev', true],
    ['keep-in-touch-d58.pages.dev', false],
    ['evilkeep-in-touch-d58.pages.dev', false],
    [null, false], // plain 127.0.0.1
  ];
  for (const [host,want] of cases) {
    const ctx=await b.newContext(); await ctx.route(/fonts\.(googleapis|gstatic)\.com/, r => r.abort());
    if(host) await ctx.addInitScript(h=>{window.KIT_TEST_HOST=h;}, host);
    const p=await ctx.newPage(); p.on('pageerror',e=>errs.push(e.message));
    await p.goto('http://127.0.0.1:8766/'); await p.waitForTimeout(500);
    const shown=await p.isVisible('#previewBanner');
    const href=shown?await p.getAttribute('#previewBanner a','href'):null;
    const ok=shown===want&&(!want||href==='https://keep-in-touch-d58.pages.dev/');
    if(!ok) fails++;
    console.log(ok?'ok  ':'FAIL', host||'127.0.0.1', '| banner shown:', shown, href?'| link: '+href:'');
    // the banner should survive switching views
    if(want){ await p.click('nav.tabs a[href="#people"]'); await p.waitForTimeout(200);
      const still=await p.isVisible('#previewBanner'); if(!still) fails++; console.log(still?'ok  ':'FAIL','  still shown on People:', still); }
    await ctx.close();
  }
  console.log('ERRORS',errs); await b.close();
  if(fails||errs.length) process.exit(1);
})();
