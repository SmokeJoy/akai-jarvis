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
  
  const url = 'https://www.apkmirror.com/apk/disney/disney-android-tv/disney-android-tv-26-20-0rc3-2026-11-02-release/';
  console.log('Navigating to release page:', url);
  await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 35000 });
  await new Promise(r => setTimeout(r, 3000));

  const variants = await page.evaluate(() => {
    const table = document.querySelector('.table-row-group, .variants-table');
    if (!table) return [];
    const rows = table.querySelectorAll('.table-row');
    return Array.from(rows).map(row => {
      const cells = Array.from(row.querySelectorAll('.table-cell')).map(c => c.innerText.trim());
      const link = row.querySelector('a')?.href || '';
      return { cells, link };
    });
  });

  console.log('Variants found:', JSON.stringify(variants, null, 2));
  fs.writeFileSync('scratch/disney_variants.json', JSON.stringify(variants, null, 2), 'utf8');
  await browser.close();
})();
