const https = require('https');

const url = 'https://apkpure.net/it/raiplay-per-android-tv/it.rainet.androidtv/download/4.2.11';

https.get(url, { headers: { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' } }, res => {
    console.log('Status:', res.statusCode);
    console.log('Location:', res.headers.location);
    let data = '';
    res.on('data', chunk => data += chunk);
    res.on('end', () => {
        const matches = [...data.matchAll(/href="([^"]+\.apk[^"]*)"/gi)];
        console.log('APK links:', matches.map(m => m[1]));
        const dLinks = [...data.matchAll(/href="([^"]*d\.apkpure[^"]*)"/gi)];
        console.log('d.apkpure links:', dLinks.map(m => m[1]));
    });
}).on('error', err => console.log('error', err.message));
