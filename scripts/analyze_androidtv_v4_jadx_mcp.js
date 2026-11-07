const { spawn } = require('child_process');
const path = require('path');
const readline = require('readline');
const fs = require('fs');

const jdkPath = path.resolve(__dirname, '..', 'tools', 'jdk-17');
const nodeBin = path.resolve(__dirname, '..', 'tools', 'nodejs');
const jadxCmd = path.resolve(__dirname, '..', 'tools', 'mcp', 'node_modules', '.bin', 'jadx-mcp.cmd');
const apkPath = path.resolve(__dirname, '..', 'scratch', 'v4_androidtv_splits', 'base.apk');

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
    console.log(">>> SENDING:", JSON.stringify(obj).substring(0, 100));
    p.stdin.write(JSON.stringify(obj) + '\n');
}

const analysis = {};

rl.on('line', (line) => {
    try {
        console.log("<<< RECV:", line.substring(0, 120));
        const msg = JSON.parse(line);
        if (msg.id === 1) {
            // First do tools/list
            send({ jsonrpc: '2.0', id: 2, method: 'tools/list', params: {} });
        } else if (msg.id === 2) {
            // Check get_class_source of PlayerActivity
            send({ jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'get_class_source', arguments: { class: 'it.rainet.androidtv.ui.PlayerActivity' } } });
        } else if (msg.id === 3) {
            if (msg.result && msg.result.content) {
                fs.writeFileSync('scratch/PlayerActivity_v4_androidtv.java', msg.result.content[0].text);
                console.log("Saved scratch/PlayerActivity_v4_androidtv.java! Length:", msg.result.content[0].text.length);
            }
            // Check get_class_source of PlayerStatus
            send({ jsonrpc: '2.0', id: 4, method: 'tools/call', params: { name: 'get_class_source', arguments: { class: 'it.rainet.androidtv.core.PlayerStatus' } } });
        } else if (msg.id === 4) {
            if (msg.result && msg.result.content) {
                fs.writeFileSync('scratch/PlayerStatus_v4_androidtv.java', msg.result.content[0].text);
                console.log("Saved scratch/PlayerStatus_v4_androidtv.java! Length:", msg.result.content[0].text.length);
            }
            // Check get_class_source of RaiPlayTvApp
            send({ jsonrpc: '2.0', id: 5, method: 'tools/call', params: { name: 'get_class_source', arguments: { class: 'it.rainet.androidtv.core.RaiPlayTvApp' } } });
        } else if (msg.id === 5) {
            if (msg.result && msg.result.content) {
                fs.writeFileSync('scratch/RaiPlayTvApp_v4_androidtv.java', msg.result.content[0].text);
                console.log("Saved scratch/RaiPlayTvApp_v4_androidtv.java! Length:", msg.result.content[0].text.length);
            }
            // Search for WEB_MESSAGE_LISTENER
            send({ jsonrpc: '2.0', id: 6, method: 'tools/call', params: { name: 'search_code', arguments: { query: 'WEB_MESSAGE_LISTENER' } } });
        } else if (msg.id === 6) {
            analysis.web_message_listener = msg.result;
            // Search for WebMessageBridgeInstaller
            send({ jsonrpc: '2.0', id: 7, method: 'tools/call', params: { name: 'search_code', arguments: { query: 'WebMessageBridgeInstaller' } } });
        } else if (msg.id === 7) {
            analysis.web_message_bridge_installer = msg.result;
            // Search for NativePlayerAdapter
            send({ jsonrpc: '2.0', id: 8, method: 'tools/call', params: { name: 'search_code', arguments: { query: 'NativePlayerAdapter' } } });
        } else if (msg.id === 8) {
            analysis.native_player_adapter = msg.result;
            fs.writeFileSync('scratch/jadx_mcp_androidtv_v4_search.json', JSON.stringify(analysis, null, 2));
            console.log("ALL JADX MCP CALLS FINISHED SUCCESSFULLY!");
            p.kill();
            process.exit(0);
        }
    } catch (e) {
        console.error("Parse error:", e);
    }
});

p.stderr.on('data', d => {
    const s = d.toString();
    if (s.includes('ERROR') || s.includes('Engine ready')) console.log("STDERR:", s.trim());
});

send({
    jsonrpc: '2.0',
    id: 1,
    method: 'initialize',
    params: {
        protocolVersion: '2024-11-05',
        clientInfo: { name: 'androidtv-v4-analysis', version: '1.0' },
        capabilities: {}
    }
});
