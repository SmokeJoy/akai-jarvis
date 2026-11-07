const { spawn } = require('child_process');
const path = require('path');
const readline = require('readline');
const fs = require('fs');

const jdkPath = path.resolve(__dirname, '..', 'tools', 'jdk-17');
const nodeBin = path.resolve(__dirname, '..', 'tools', 'nodejs');
const jadxCmd = path.resolve(__dirname, '..', 'tools', 'mcp', 'node_modules', '.bin', 'jadx-mcp.cmd');
const apkPath = path.resolve(__dirname, '..', 'scratch', 'raiplay_4.2.11.apk');

const env = {
    ...process.env,
    JAVA_HOME: jdkPath,
    PATH: `${nodeBin};${jdkPath}\\bin;${process.env.PATH || ''}`
};

const p = spawn(jadxCmd, ['--file', apkPath, '--transport', 'stdio'], {
    env: env,
    shell: true
});

const rl = readline.createInterface({ input: p.stdout });

function send(obj) {
    p.stdin.write(JSON.stringify(obj) + '\n');
}

const results = {};

rl.on('line', (line) => {
    try {
        const msg = JSON.parse(line);
        if (msg.id === 1) {
            console.log("JADX MCP initialized.");
            // 1. Get Main Activity Class
            send({ jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'get_main_activity_class', arguments: {} } });
        } else if (msg.id === 2) {
            results.main_activity = msg.result;
            console.log("Main activity result:", JSON.stringify(msg.result).substring(0, 200));

            // 2. Search for WEB_MESSAGE_LISTENER
            send({ jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'search_code', arguments: { query: 'WEB_MESSAGE_LISTENER' } } });
        } else if (msg.id === 3) {
            results.web_message_listener = msg.result;
            console.log("WEB_MESSAGE_LISTENER search:", JSON.stringify(msg.result).substring(0, 200));

            // 3. Search for WebMessageBridgeInstaller
            send({ jsonrpc: '2.0', id: 4, method: 'tools/call', params: { name: 'search_code', arguments: { query: 'WebMessageBridgeInstaller' } } });
        } else if (msg.id === 4) {
            results.web_message_bridge_installer = msg.result;
            console.log("WebMessageBridgeInstaller search:", JSON.stringify(msg.result).substring(0, 200));

            // 4. Search for NativePlayerAdapter
            send({ jsonrpc: '2.0', id: 5, method: 'tools/call', params: { name: 'search_code', arguments: { query: 'NativePlayerAdapter' } } });
        } else if (msg.id === 5) {
            results.native_player_adapter = msg.result;
            console.log("NativePlayerAdapter search:", JSON.stringify(msg.result).substring(0, 200));

            // 5. Search for NativeHostBridge
            send({ jsonrpc: '2.0', id: 6, method: 'tools/call', params: { name: 'search_code', arguments: { query: 'NativeHostBridge' } } });
        } else if (msg.id === 6) {
            results.native_host_bridge = msg.result;
            console.log("NativeHostBridge search:", JSON.stringify(msg.result).substring(0, 200));

            // 6. Search for ExoPlayer usage
            send({ jsonrpc: '2.0', id: 7, method: 'tools/call', params: { name: 'search_code', arguments: { query: 'com.google.android.exoplayer2' } } });
        } else if (msg.id === 7) {
            results.exoplayer_refs = msg.result;
            console.log("ExoPlayer search:", JSON.stringify(msg.result).substring(0, 200));

            // 7. Get class source of MainLeanbackActivity
            send({ jsonrpc: '2.0', id: 8, method: 'tools/call', params: { name: 'get_class_source', arguments: { class: 'it.rainet.androidtv.ui.MainLeanbackActivity' } } });
        } else if (msg.id === 8) {
            results.main_leanback_activity = msg.result;
            fs.writeFileSync('scratch/jadx_mcp_results_v4.json', JSON.stringify(results, null, 2));
            console.log("Saved full results to scratch/jadx_mcp_results_v4.json");
            p.kill();
            process.exit(0);
        }
    } catch (e) {
        console.error("Parse error:", e);
    }
});

p.stderr.on('data', d => {
    const s = d.toString();
    if (s.includes('ERROR') || s.includes('Engine ready')) {
        console.log("JADX STDERR:", s.trim());
    }
});

send({
    jsonrpc: '2.0',
    id: 1,
    method: 'initialize',
    params: {
        protocolVersion: '2024-11-05',
        clientInfo: { name: 'antigravity-analysis', version: '1.0' },
        capabilities: {}
    }
});
