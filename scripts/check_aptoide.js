const https = require('https');

const url = 'https://ws75.aptoide.com/api/7/apps/get?package_name=it.rainet.androidtv';

https.get(url, (res) => {
    let data = '';
    res.on('data', chunk => data += chunk);
    res.on('end', () => {
        try {
            const json = JSON.parse(data);
            if (json.nodes && json.nodes.meta) {
                const meta = json.nodes.meta.data;
                console.log('App Title:', meta.name);
                console.log('Package:', meta.package);
                console.log('Version:', meta.file.vername);
                console.log('VersionCode:', meta.file.vercode);
                console.log('Download URL:', meta.file.path);
                console.log('MD5:', meta.file.md5sum);
                console.log('Size:', meta.file.filesize);
            } else {
                console.log('Response:', JSON.stringify(json).slice(0, 500));
            }
        } catch (e) {
            console.error('Parse error:', e.message);
        }
    });
}).on('error', err => console.error(err.message));
