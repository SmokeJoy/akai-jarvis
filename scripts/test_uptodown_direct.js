const https = require('https');

const url = 'https://raiplay-android-tv.en.uptodown.com/android/download/1174865308';

https.get(url, { headers: { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' } }, res => {
    let data = '';
    res.on('data', chunk => data += chunk);
    res.on('end', () => {
        console.log('Status:', res.statusCode);
        const match = data.match(/data-url="([^"]+)"/i) || data.match(/href="([^"]+\.(?:apk|xapk)[^"]*)"/i);
        if (match) console.log('Direct download link:', match[1]);
        const links = [...data.matchAll(/class="button download"[^>]*href="([^"]+)"/g)];
        if (links.length) console.log('Download button href:', links.map(l => l[1]));
    });
}).on('error', err => console.log('error', err.message));
