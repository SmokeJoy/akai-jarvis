const fs = require('fs');
const html = fs.readFileSync('scratch/uptodown_versions.html', 'utf8');

const regex = /<div class="version"[^>]*>([\s\S]*?)<\/div>/g;
let match;
while ((match = regex.exec(html)) !== null) {
    console.log(match[1].trim());
}

const itemRegex = /<div[^>]*data-url="([^"]+)"[^>]*>([\s\S]*?)<\/div>/g;
while ((match = itemRegex.exec(html)) !== null) {
    console.log("data-url:", match[1]);
}
