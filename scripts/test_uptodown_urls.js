const https = require('https');

const urls = [
    'https://raiplay-smart-tv.it.uptodown.com/android',
    'https://raiplay-smart-tv.en.uptodown.com/android',
    'https://raiplay-android-tv.en.uptodown.com/android',
    'https://raiplay.it.uptodown.com/android'
];

urls.forEach(url => {
    https.get(url, { headers: { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' } }, res => {
        console.log(url, '->', res.statusCode);
    }).on('error', err => console.log(url, 'error', err.message));
});
