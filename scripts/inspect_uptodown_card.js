const https = require('https');

const url = 'https://raiplay-android-tv.en.uptodown.com/android/versions';

https.get(url, { headers: { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' } }, res => {
    let data = '';
    res.on('data', chunk => data += chunk);
    res.on('end', () => {
        const idx = data.indexOf('4.3.2');
        if (idx >= 0) {
            console.log(data.substring(Math.max(0, idx - 200), idx + 200));
        }
    });
});
