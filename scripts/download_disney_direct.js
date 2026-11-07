const puppeteer = require('../tools/mcp/node_modules/puppeteer-core');
const fs = require('fs');
const path = require('path');

const CHROME_PATH = "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe";
const DOWNLOAD_DIR = path.resolve(__dirname, '..', 'scratch', 'disney_download');

if (!fs.existsSync(DOWNLOAD_DIR)) {
    fs.mkdirSync(DOWNLOAD_DIR, { recursive: true });
}

async function run() {
    console.log("Launching Chrome for Disney+ download...");
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

        const directLink = 'https://www.apkmirror.com/wp-content/themes/APKMirror/download.php?id=17056431&key=eb8fafb0f20d672d5e5e1cc664f595517488d292';
        console.log("Direct download trigger link:", directLink);
        await client.send('Page.navigate', { url: directLink });

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
