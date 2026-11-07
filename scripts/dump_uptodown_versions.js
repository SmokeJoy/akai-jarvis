const https = require('https');

const url = 'https://raiplay-android-tv.en.uptodown.com/android/versions';

https.get(url, { headers: { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' } }, res => {
    let data = '';
    res.on('data', chunk => data += chunk);
    res.on('end', () => {
        const matches = [...data.matchAll(/class="version"[^>]*>([^<]+)<\/span>/g)];
        console.log('Class version matches:', matches.map(m => m[1]));
        const links = [...data.matchAll(/href="([^"]*download[^"]*)"/g)];
        console.log('Download links:', links.map(m => m[1]));
    });
}).on('error', err => console.log('error', err.message));
