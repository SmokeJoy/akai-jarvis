const puppeteer = require('../tools/mcp/node_modules/puppeteer-core');
const fs = require('fs');
const path = require('path');

const CHROME_PATH = "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe";
const DOWNLOAD_DIR = path.resolve(__dirname, '..', 'scratch', 'v4_androidtv_download');

if (!fs.existsSync(DOWNLOAD_DIR)) {
    fs.mkdirSync(DOWNLOAD_DIR, { recursive: true });
}

async function run() {
    console.log("Launching headed Chrome for Android TV 4.2.11...");
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
            console.log(">>> CDP EVENT: downloadWillBegin!", e.suggestedFilename);
        });

        client.on('Browser.downloadProgress', (e) => {
            if (e.state === 'completed') {
                console.log(`>>> CDP EVENT: downloadProgress COMPLETED! totalBytes=${e.totalBytes}`);
            }
        });

        const releaseUrl = 'https://www.apkmirror.com/apk/rai-radiotelevisione-italiana-s-p-a/raiplay-per-android-tv-android-tv/raiplay-per-android-tv-4-2-11-release/';
        console.log("Navigating to release page:", releaseUrl);
        await page.goto(releaseUrl, { waitUntil: 'domcontentloaded', timeout: 45000 });
        await new Promise(r => setTimeout(r, 4000));

        // Find the download variant button
        const variantLinks = await page.evaluate(() => {
            const rows = Array.from(document.querySelectorAll('.table-row'));
            const res = [];
            for (const r of rows) {
                const a = r.querySelector('a.accent_color');
                if (a) {
                    res.push({ text: a.innerText.trim(), href: a.href });
                }
            }
            return res;
        });

        console.log("Variant links found:", variantLinks);

        let targetUrl = null;
        if (variantLinks.length > 0) {
            targetUrl = variantLinks[0].href;
        } else {
            targetUrl = await page.evaluate(() => {
                const links = Array.from(document.querySelectorAll('a'));
                const match = links.find(l => l.href && l.href.includes('4-2-11') && l.href.includes('download') && !l.href.endsWith('#downloads'));
                return match ? match.href : null;
            });
        }

        console.log("Target variant page:", targetUrl);
        if (!targetUrl) {
            console.log("Taking screenshot...");
            await page.screenshot({ path: path.join(DOWNLOAD_DIR, 'page_error.png') });
            return;
        }

        await page.goto(targetUrl, { waitUntil: 'domcontentloaded', timeout: 45000 });
        await new Promise(r => setTimeout(r, 4000));

        const downloadStepUrl = await page.evaluate(() => {
            const btn = document.querySelector('a.downloadButton');
            return btn ? btn.href : null;
        });

        console.log("Download step URL:", downloadStepUrl);
        await page.goto(downloadStepUrl, { waitUntil: 'domcontentloaded', timeout: 45000 });
        await new Promise(r => setTimeout(r, 4000));

        // Get direct download link
        const directLink = await page.evaluate(() => {
            const a = document.querySelector('a#download-link') || Array.from(document.querySelectorAll('a')).find(el => el.innerText.toLowerCase().includes('here'));
            return a ? a.href : null;
        });

        console.log("Direct download trigger link:", directLink);
        if (directLink) {
            await client.send('Page.navigate', { url: directLink });
        }

        console.log("Waiting for download to complete (up to 40s)...");
        for (let i = 0; i < 40; i++) {
            await new Promise(r => setTimeout(r, 1000));
            const files = fs.readdirSync(DOWNLOAD_DIR);
            const downloaded = files.filter(f => !f.endsWith('.crdownload') && (f.endsWith('.apk') || f.endsWith('.apkm') || f.endsWith('.zip')));
            const cr = files.filter(f => f.includes('crdownload'));
            if (downloaded.length > 0 && cr.length === 0) {
                console.log("SUCCESS! Download completed:", downloaded);
                break;
            }
        }

    } catch (err) {
        console.error("Error during download:", err);
    } finally {
        await browser.close();
        console.log("Browser closed.");
    }
}

run();
