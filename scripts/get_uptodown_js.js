const https = require('https');

const url = 'https://raiplay-android-tv.en.uptodown.com/android/download/1174865308';

https.get(url, { headers: { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' } }, res => {
    let data = '';
    res.on('data', chunk => data += chunk);
    res.on('end', () => {
        const jsMatches = [...data.matchAll(/<script[^>]*src="([^"]+)"/gi)];
        console.log('JS files:', jsMatches.map(m => m[1]));
    });
});
