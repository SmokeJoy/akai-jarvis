const puppeteer = require('C:/Users/danie/OneDrive/Documenti/Antygravity/Akay/tools/mcp/node_modules/puppeteer-core');
const path = require('path');
const fs = require('fs');

(async () => {
  const downloadDir = path.resolve('scratch/disney_download');
  if (!fs.existsSync(downloadDir)) fs.mkdirSync(downloadDir, { recursive: true });

  const browser = await puppeteer.launch({
    executablePath: 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
    headless: false, // visible for Cloudflare turnstile if needed
    args: ['--no-sandbox', '--disable-blink-features=AutomationControlled']
  });

  const page = await browser.newPage();
  const client = await page.target().createCDPSession();
  await client.send('Browser.setDownloadBehavior', {
    behavior: 'allowAndName',
    downloadPath: downloadDir,
    eventsEnabled: true
  });

  client.on('Browser.downloadWillBegin', (e) => {
    console.log('Download starting:', e.suggestedFilename, 'guid:', e.guid);
  });
  client.on('Browser.downloadProgress', (e) => {
    if (e.state === 'completed') {
      console.log('Download completed successfully!');
    }
  });

  await page.setUserAgent('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36');

  const variantUrl = 'https://www.apkmirror.com/apk/disney/disney-android-tv/disney-android-tv-26-20-0rc3-2026-11-02-release/disney-android-tv-26-20-0rc3-2026-11-02-2-android-apk-download/';
  console.log('Step 1: Navigating to variant page:', variantUrl);
  await page.goto(variantUrl, { waitUntil: 'domcontentloaded', timeout: 40000 });
  await new Promise(r => setTimeout(r, 3000));

  // Find the download button
  const downloadPageUrl = await page.evaluate(() => {
    const btn = document.querySelector('a.downloadButton');
    return btn ? btn.href : null;
  });

  if (!downloadPageUrl) {
    console.error('Download button not found!');
    await browser.close();
    return;
  }

  console.log('Step 2: Navigating to download step page:', downloadPageUrl);
  await page.goto(downloadPageUrl, { waitUntil: 'domcontentloaded', timeout: 40000 });
  await new Promise(r => setTimeout(r, 4000));

  // Find final download link if needed or wait for download to trigger
  const finalBtn = await page.evaluate(() => {
    const btn = document.querySelector('a[data-google-vignette="false"].btn, a.accent_bg.btn');
    return btn ? btn.href : null;
  });

  if (finalBtn) {
    console.log('Step 3: Clicking final download button:', finalBtn);
    try {
      await page.goto(finalBtn, { waitUntil: 'domcontentloaded', timeout: 15000 });
    } catch (e) {
      console.log('Navigation event finished (download trigger):', e.message);
    }
  }

  console.log('Waiting for download to finish (max 45 seconds)...');
  for (let i = 0; i < 45; i++) {
    await new Promise(r => setTimeout(r, 1000));
    const files = fs.readdirSync(downloadDir);
    const completed = files.find(f => !f.endsWith('.crdownload') && (f.endsWith('.apk') || f.endsWith('.apkm') || f.endsWith('.zip')));
    if (completed) {
      console.log('Found completed download:', completed);
      break;
    }
  }

  await browser.close();
})();
