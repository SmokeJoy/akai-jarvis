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

  const url = 'https://www.apkmirror.com/apk/disney/disney-android-tv/disney-android-tv-26-20-0rc3-2026-11-02-release/disney-android-tv-26-20-0rc3-2026-11-02-2-android-apk-download/download/?key=678edae52f098eb770cb587f674df058b654c71f';
  await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 35000 });
  await new Promise(r => setTimeout(r, 4000));

  const links = await page.evaluate(() => {
    return Array.from(document.querySelectorAll('a')).map(a => ({ text: a.innerText.trim(), href: a.href })).filter(a => a.href.includes('download') || a.text.toLowerCase().includes('download') || a.text.toLowerCase().includes('here'));
  });

  console.log('Download links on page:', JSON.stringify(links, null, 2));
  fs.writeFileSync('scratch/download_links.json', JSON.stringify(links, null, 2), 'utf8');
  await browser.close();
})();
