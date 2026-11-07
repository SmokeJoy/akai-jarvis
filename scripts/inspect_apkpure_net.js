const https = require('https');

const url = 'https://apkpure.net/it/raiplay-per-android-tv/it.rainet.androidtv/download/4.2.11';

https.get(url, { headers: { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' } }, res => {
    let data = '';
    res.on('data', chunk => data += chunk);
    res.on('end', () => {
        const titleMatch = data.match(/<title>([^<]+)<\/title>/i);
        console.log('Title:', titleMatch ? titleMatch[1] : 'no title');
        const btnMatches = [...data.matchAll(/<a[^>]*class="[^"]*download[^"]*"[^>]*href="([^"]+)"/gi)];
        console.log('Download buttons:', btnMatches.map(m => m[1]));
        const anyA = [...data.matchAll(/<a[^>]*href="([^"]+)"[^>]*>([^<]+)<\/a>/g)].filter(m => m[2].toLowerCase().includes('download') || m[2].toLowerCase().includes('scarica'));
        console.log('Download A tags:', anyA.map(m => `${m[2].trim()} -> ${m[1]}`));
    });
});
