const https = require('https');

const url = 'https://raiplay-android-tv.en.uptodown.com/android/versions';

https.get(url, { headers: { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' } }, res => {
    let data = '';
    res.on('data', chunk => data += chunk);
    res.on('end', () => {
        const regex = /<div[^>]*data-url="([^"]+)"[^>]*>[\s\S]*?<span class="version">([^<]+)<\/span>/g;
        let m;
        while ((m = regex.exec(data)) !== null) {
            console.log(`Version ${m[2]} URL: ${m[1]}`);
        }
    });
});
