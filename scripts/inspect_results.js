const fs = require('fs');
const data = JSON.parse(fs.readFileSync('scratch/jadx_mcp_results_v4.json', 'utf8'));

console.log("=== MAIN LEANBACK ACTIVITY ===");
if (data.main_leanback_activity && data.main_leanback_activity.content) {
    const text = data.main_leanback_activity.content[0].text;
    const lines = text.split('\n');
    console.log("Total lines:", lines.length);
    console.log("First 35 lines:\n" + lines.slice(0, 35).join('\n'));
}

console.log("\n=== WEB_MESSAGE_LISTENER SEARCH RESULTS ===");
console.log(data.web_message_listener.content[0].text);
