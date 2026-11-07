const https = require('https');

const url = 'https://raiplay-android-tv.en.uptodown.com/android/download/1174865308';

https.get(url, { headers: { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' } }, res => {
    let data = '';
    res.on('data', chunk => data += chunk);
    res.on('end', () => {
        const matches = [...data.matchAll(/id="detail-download-button"[^>]*data-url="([^"]+)"/g)];
        console.log('Button matches:', matches.map(m => m[1]));
        const postDownload = [...data.matchAll(/href="([^"]*post-download[^"]*)"/g)];
        console.log('Post download matches:', postDownload.map(m => m[1]));
    });
});
