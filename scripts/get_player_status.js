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
            console.log("JADX MCP initialized. Requesting PlayerStatus source...");
            send({
                jsonrpc: '2.0',
                id: 2,
                method: 'tools/call',
                params: {
                    name: 'get_class_source',
                    arguments: {
                        class: 'it.rainet.androidtv.core.PlayerStatus'
                    }
                }
            });
        } else if (msg.id === 2) {
            if (msg.result && msg.result.content) {
                fs.writeFileSync('scratch/PlayerStatus_v4.java', msg.result.content[0].text);
                console.log("Saved scratch/PlayerStatus_v4.java successfully!");
            }
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
        clientInfo: { name: 'get-player-status', version: '1.0' },
        capabilities: {}
    }
});
