const https = require('https');

const url = 'https://raiplay-android-tv.en.uptodown.com/android/versions';

https.get(url, { headers: { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' } }, res => {
    let data = '';
    res.on('data', chunk => data += chunk);
    res.on('end', () => {
        console.log('Status:', res.statusCode);
        const matches = [...data.matchAll(/data-url="([^"]+)"[^>]*>[\s\r\n]*<span class="version">([^<]+)<\/span>/g)];
        console.log(`Found ${matches.length} versions:`);
        matches.forEach(m => console.log(`- ${m[2]}: ${m[1]}`));
    });
}).on('error', err => console.log('error', err.message));
