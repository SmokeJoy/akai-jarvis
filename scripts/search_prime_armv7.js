const puppeteer = require('C:/Users/danie/OneDrive/Documenti/Antygravity/Akay/tools/mcp/node_modules/puppeteer-core');
const fs = require('fs');

(async () => {
  const browser = await puppeteer.launch({
    executablePath: 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
    headless: 'new',
    args: ['--no-sandbox', '--disable-blink-features=AutomationControlled']
  });
  const page = await browser.newPage();
  await page.setUserAgent('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36');

  console.log('Navigating to Prime Video arm-v7a page...');
  await page.goto('https://www.apkmirror.com/apk/amazon-mobile-llc/prime-video-android-tv-arm-v7a/', { waitUntil: 'domcontentloaded', timeout: 35000 });
  await new Promise(r => setTimeout(r, 3000));

  const releases = await page.evaluate(() => {
    const rows = document.querySelectorAll('.appRow');
    return Array.from(rows).slice(0, 10).map(r => {
      const title = r.querySelector('.appRowTitle')?.innerText?.trim() || '';
      const link = r.querySelector('a.downloadLink')?.href || r.querySelector('a')?.href || '';
      const date = r.querySelector('.dateyear_utc')?.innerText?.trim() || '';
      return { title, link, date };
    });
  });

  console.log('Prime Video arm-v7a releases:', JSON.stringify(releases, null, 2));
  fs.writeFileSync('scratch/prime_armv7_releases.json', JSON.stringify(releases, null, 2), 'utf8');
  await browser.close();
})();
