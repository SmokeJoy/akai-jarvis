const https = require('https');

const url = 'https://raiplay-android-tv.it.uptodown.com/android/scarica';

const req = https.get(url, {
    headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
    }
}, (res) => {
    let data = '';
    res.on('data', chunk => data += chunk);
    res.on('end', () => {
        console.log('Status:', res.statusCode);
        const match = data.match(/data-url="([^"]+)"/i) || data.match(/href="([^"]+\.apk[^"]*)"/i);
        if (match) {
            console.log('Download URL match:', match[1]);
        }
        const titleMatch = data.match(/<title>([^<]+)<\/title>/i);
        if (titleMatch) console.log('Title:', titleMatch[1]);
        const verMatch = data.match(/class="version"[^>]*>([^<]+)</i);
        if (verMatch) console.log('Version:', verMatch[1]);
    });
});
req.on('error', err => console.error(err.message));
