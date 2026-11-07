const https = require('https');

const url = 'https://www.apkmirror.com/apk/rai-radiotelevisione-italiana-s-p-a/raiplay-fire-tv-android-tv/raiplay-fire-tv-android-tv-4-2-11-release/raiplay-fire-tv-android-tv-4-2-11-android-apk-download/';

const options = {
    headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'en-US,en;q=0.5'
    }
};

https.get(url, options, (res) => {
    let data = '';
    res.on('data', chunk => data += chunk);
    res.on('end', () => {
        console.log('Status:', res.statusCode);
        const match = data.match(/href="([^"]*download\.php[^"]*)"/i) || data.match(/class="[^"]*downloadButton[^"]*"[^>]*href="([^"]+)"/i);
        if (match) {
            console.log('Download link:', match[1]);
        } else {
            console.log('No direct download button match, inspecting links...');
            const links = [...data.matchAll(/href="([^"]*download[^"]*)"/gi)].map(m => m[1]);
            console.log('Found download links:', [...new Set(links)].slice(0, 10));
        }
    });
}).on('error', err => console.error('Error:', err.message));
