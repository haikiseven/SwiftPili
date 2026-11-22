import puppeteer from 'puppeteer';
const CH='/root/.cache/puppeteer/chrome/linux-131.0.6778.204/chrome-linux64/chrome';
const b = await puppeteer.launch({ executablePath: CH, headless: true,
  args:['--no-sandbox','--disable-setuid-sandbox','--force-color-profile=srgb',
        '--hide-scrollbars','--disable-lcd-text','--font-render-hinting=none']});
for (const name of ['light','dark','tinted']) {
  const p = await b.newPage();
  await p.setViewport({ width:1024, height:1024, deviceScaleFactor:1 });
  await p.goto('file://'+import.meta.dirname+`/render-${name}.html`, {waitUntil:'load'});
  await new Promise(r=>setTimeout(r,400));            // let filters settle
  const el = await p.$('#icon');
  await el.screenshot({ path:`out-${name}.png`, omitBackground:true });
  console.log('rendered', name);
  await p.close();
}
await b.close();
