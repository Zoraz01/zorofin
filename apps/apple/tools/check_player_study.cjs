// Review-only HTML interaction checks; never opens a server or plays real media.
// Usage: PLAYWRIGHT_MODULE=<module path> node check_player_study.cjs <rendered HTML>
const assert=require('node:assert/strict');
const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const {pathToFileURL}=require('node:url');
(async()=>{
 assert(process.argv[2], 'Pass the rendered player study HTML path.');
 const browser=await chromium.launch({channel:'chrome',headless:true,args:['--disable-gpu']});
 try {
  const page=await browser.newPage();const errors=[];page.on('pageerror',e=>errors.push(e.message));
  for(const width of [320,390,736,1024]){
   await page.setViewportSize({width,height:900});await page.goto(pathToFileURL(process.argv[2]).href);
   const frame=page.frames().find(f=>f!==page.mainFrame());await frame.waitForSelector('.zp-screen');
   await frame.getByRole('button',{name:'Next variant',exact:true}).click();
   assert.equal(await frame.locator('[data-variant="Quiet controls"]').isVisible(),true);
   await frame.getByRole('button',{name:'Previous variant',exact:true}).click();
   assert.equal(await frame.locator('[data-variant="Cinematic"]').isVisible(),true);
   for(const layout of ['cinematic','quiet']){
    // Select the same locally rendered variant without relying on host carousel chrome.
    await frame.evaluate(layout=>{document.querySelectorAll('[data-variant]').forEach(e=>e.hidden=e.querySelector('.zp-stage').dataset.layout!==layout)},layout);
    const stage=frame.locator(`[data-layout="${layout}"]`).first();
    const overflow=await frame.evaluate(()=>({page:document.documentElement.scrollWidth,viewport:innerWidth}));
    assert(overflow.page<=overflow.viewport,JSON.stringify(overflow));
    const spacing=await stage.evaluate(e=>{const transport=e.querySelector('.zp-transport').getBoundingClientRect(),time=e.querySelector('.zp-time-row').getBoundingClientRect();return {bottom:transport.bottom,timeTop:time.top}});
    assert(spacing.timeTop-spacing.bottom>=8,JSON.stringify({width,layout,spacing}));
    await stage.getByRole('button',{name:'Episodes',exact:true}).click();
    await stage.getByRole('combobox',{name:'Season'}).selectOption('2');
    await stage.getByRole('button',{name:'Play episode 4, Into the Dark',exact:true}).click();
    assert.equal(await stage.locator('.zp-subtitle').textContent(),'S2:E4 · Into the Dark');
    await stage.getByRole('button',{name:'Pause',exact:true}).click();
    await stage.getByRole('button',{name:'Sound and subtitles',exact:true}).click();
    await stage.getByRole('button',{name:'English · CC',exact:true}).click();
    assert.equal(await stage.getByRole('button',{name:'English · CC',exact:true}).getAttribute('aria-pressed'),'true');
    await stage.getByRole('button',{name:'Close options',exact:true}).click();
    await stage.locator('.zp-panel-wrap').waitFor({state:'hidden'});
    assert.equal(await stage.getByRole('button',{name:'Play',exact:true}).count(),1,'Paused state must survive panel');
    await stage.getByRole('button',{name:'More',exact:true}).click();
    await stage.getByRole('button',{name:'Quality · 40 Mbps',exact:true}).click();
    await stage.getByRole('button',{name:'20 Mbps',exact:true}).click();
    assert.equal(await stage.getByRole('button',{name:'20 Mbps',exact:true}).getAttribute('aria-pressed'),'true');
    await stage.getByRole('button',{name:'Close options',exact:true}).click();
    await stage.getByRole('button',{name:'More',exact:true}).click();
    await stage.getByRole('button',{name:'Lock controls',exact:true}).click();
    assert.equal(await stage.locator('.zp-chrome').evaluate(e=>e.inert),true);
    await stage.getByRole('button',{name:'Unlock',exact:true}).click();
    assert.equal(await stage.locator('.zp-chrome').evaluate(e=>e.inert),false);
    await frame.evaluate(()=>new Promise(requestAnimationFrame));
    if(process.env.PLAYER_SCREENSHOTS) await page.screenshot({path:require('node:path').join(process.env.PLAYER_SCREENSHOTS,`player-${layout}-${width}.png`),fullPage:true});
    console.log(JSON.stringify({width,layout,overflow,episodeSelection:true,subtitles:true,quality:true,pausePreserved:true,lock:true}));
   }
  }
  assert.deepEqual(errors,[]);console.log('No browser runtime errors.');
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1});
