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

rl.on('line', (line) => {
    try {
        const msg = JSON.parse(line);
        if (msg.id === 1) {
            console.log("JADX MCP initialized.");
            // Search classes with 'Player' in it.rainet
            send({ jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'search_code', arguments: { query: 'it.rainet.androidtv.player' } } });
        } else if (msg.id === 2) {
            console.log("Result player package search:", JSON.stringify(msg.result, null, 2));
            
            // Search for VideoPlayerActivity or VideoPlayerFragment
            send({ jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'search_code', arguments: { query: 'VideoPlayerActivity' } } });
        } else if (msg.id === 3) {
            console.log("Result VideoPlayerActivity search:", JSON.stringify(msg.result, null, 2));

            // Search for ExoPlayer instantiation in it.rainet
            send({ jsonrpc: '2.0', id: 4, method: 'tools/call', params: { name: 'search_code', arguments: { query: 'ExoPlayerFactory' } } });
        } else if (msg.id === 4) {
            console.log("Result ExoPlayerFactory search:", JSON.stringify(msg.result, null, 2));
            p.kill();
            process.exit(0);
        }
    } catch (e) {
        console.error("Error:", e);
    }
});

send({
    jsonrpc: '2.0',
    id: 1,
    method: 'initialize',
    params: {
        protocolVersion: '2024-11-05',
        clientInfo: { name: 'player-search', version: '1.0' },
        capabilities: {}
    }
});
