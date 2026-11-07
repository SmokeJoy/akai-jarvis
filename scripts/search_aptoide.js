const https = require('https');

const url = 'https://ws75.aptoide.com/api/7/apps/search?query=it.rainet.androidtv&limit=20';

https.get(url, (res) => {
    let data = '';
    res.on('data', chunk => data += chunk);
    res.on('end', () => {
        try {
            const json = JSON.parse(data);
            if (json.datalist && json.datalist.list) {
                json.datalist.list.forEach(app => {
                    console.log(`- ${app.name} (${app.package}) v${app.file.vername} [code: ${app.file.vercode}] store: ${app.store.name}`);
                });
            }
        } catch (e) {
            console.error('Parse error:', e.message);
        }
    });
}).on('error', err => console.error(err.message));
