const https = require('https');

const url = 'https://raiplay-android-tv.en.uptodown.com/android/post-download/1174865308';

https.get(url, { headers: { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' } }, res => {
    let data = '';
    res.on('data', chunk => data += chunk);
    res.on('end', () => {
        console.log('Status:', res.statusCode);
        const match = data.match(/class="post-download-item"[^>]*data-url="([^"]+)"/i) || data.match(/data-url="([^"]+)"/i);
        if (match) console.log('Post-download data-url:', match[1]);
        const links = [...data.matchAll(/href="([^"]+\.(?:apk|xapk)[^"]*)"/gi)];
        console.log('Direct apk/xapk links:', links.map(l => l[1]));
    });
});
