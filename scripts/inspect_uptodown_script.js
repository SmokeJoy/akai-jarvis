const https = require('https');

const url = 'https://raiplay-android-tv.en.uptodown.com/android/download/1174865308';

https.get(url, { headers: { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' } }, res => {
    let data = '';
    res.on('data', chunk => data += chunk);
    res.on('end', () => {
        const scriptMatches = [...data.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/gi)];
        scriptMatches.forEach(s => {
            if (s[1].includes('download') || s[1].includes('file-id') || s[1].includes('dwldng')) {
                console.log('Script match:', s[1].substring(0, 300));
            }
        });
    });
});
