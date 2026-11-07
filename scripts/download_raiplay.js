const puppeteer = require('../tools/mcp/node_modules/puppeteer-core');
const fs = require('fs');
const path = require('path');

const CHROME_PATH = "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe";
const DOWNLOAD_DIR = path.resolve(__dirname, '..', 'scratch');

async function run() {
    console.log("Launching headed Chrome...");
    const browser = await puppeteer.launch({
        executablePath: CHROME_PATH,
        headless: false,
        args: [
            '--window-size=1200,800',
            '--disable-blink-features=AutomationControlled'
        ]
    });

    try {
        const pages = await browser.pages();
        const page = pages.length > 0 ? pages[0] : await browser.newPage();
        
        const client = await page.target().createCDPSession();
        await client.send('Browser.setDownloadBehavior', {
            behavior: 'allow',
            downloadPath: DOWNLOAD_DIR,
            eventsEnabled: true
        });

        client.on('Browser.downloadWillBegin', (e) => {
            console.log(">>> CDP EVENT: downloadWillBegin!", e);
        });

        client.on('Browser.downloadProgress', (e) => {
            console.log(`>>> CDP EVENT: downloadProgress: state=${e.state}, received=${e.receivedBytes}/${e.totalBytes}`);
        });

        const variantUrl = 'https://www.apkmirror.com/apk/rai-radiotelevisione-italiana-s-p-a/raiplay-fire-tv/raiplay-fire-tv-android-tv-4-2-11-release/raiplay-fire-tv-android-tv-4-2-11-android-apk-download/';
        console.log("Navigating to variant page:", variantUrl);
        await page.goto(variantUrl, { waitUntil: 'domcontentloaded', timeout: 45000 });
        await new Promise(r => setTimeout(r, 4000));

        const downloadStepUrl = await page.evaluate(() => {
            const btn = document.querySelector('a.downloadButton');
            return btn ? btn.href : null;
        });

        console.log("Download step URL:", downloadStepUrl);
        await page.goto(downloadStepUrl, { waitUntil: 'domcontentloaded', timeout: 45000 });
        await new Promise(r => setTimeout(r, 4000));

        // Find direct trigger link
        const directLink = await page.evaluate(() => {
            const a = document.querySelector('a#download-link') || Array.from(document.querySelectorAll('a')).find(el => el.innerText.toLowerCase().includes('here'));
            return a ? a.href : null;
        });

        console.log("Triggering direct download URL:", directLink);
        
        // Trigger via CDP Page.navigate so page.goto doesn't throw ERR_ABORTED
        await client.send('Page.navigate', { url: directLink });

        console.log("Waiting for download to complete (up to 40s)...");
        for (let i = 0; i < 40; i++) {
            await new Promise(r => setTimeout(r, 1000));
            const files = fs.readdirSync(DOWNLOAD_DIR);
            const apks = files.filter(f => f.endsWith('.apk') && f !== 'raiplay_base.apk');
            const cr = files.filter(f => f.includes('crdownload'));
            if (apks.length > 0 && cr.length === 0) {
                console.log("SUCCESS! Download completed:", apks);
                break;
            }
        }

    } catch (err) {
        console.error("Error:", err);
    } finally {
        await browser.close();
        console.log("Browser closed.");
    }
}

run();
