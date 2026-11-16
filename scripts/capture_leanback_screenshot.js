const path = require('path');
const fs = require('fs');
const puppeteer = require('../tools/mcp/node_modules/puppeteer-core');

async function main() {
    const edgePath = 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe';
    if (!fs.existsSync(edgePath)) {
        console.error('Edge executable not found at:', edgePath);
        process.exit(1);
    }

    const browser = await puppeteer.launch({
        executablePath: edgePath,
        headless: 'new',
        args: ['--no-sandbox', '--disable-setuid-sandbox']
    });

    const page = await browser.newPage();
    await page.setViewport({ width: 1500, height: 1000, deviceScaleFactor: 1 });

    const htmlPath = path.resolve(__dirname, '..', 'AKAI_CUSTOM_HOME_v8_LEANBACK_COMPARAZIONE.html');
    const fileUrl = 'file:///' + htmlPath.replace(/\\/g, '/');
    console.log('Loading:', fileUrl);

    await page.goto(fileUrl, { waitUntil: 'networkidle0' });

    // 1. Screenshot Leanback v8
    const outV8 = path.resolve(__dirname, '..', 'AKAI_CUSTOM_HOME_v8_anteprima_leanback.png');
    await page.screenshot({ path: outV8, fullPage: false });
    console.log('Saved Leanback v8 screenshot to:', outV8);

    // 2. Screenshot Comparazione Prima/Dopo
    await page.evaluate(() => {
        if (typeof switchView === 'function') switchView('comparison');
    });
    await new Promise(r => setTimeout(r, 200));
    const outComp = path.resolve(__dirname, '..', 'AKAI_CUSTOM_HOME_v8_comparazione_prima_dopo.png');
    await page.screenshot({ path: outComp, fullPage: false });
    console.log('Saved Comparison screenshot to:', outComp);

    await browser.close();
    console.log('Done rendering screenshots.');
}

main().catch(err => {
    console.error('Error generating screenshots:', err);
    process.exit(1);
});
