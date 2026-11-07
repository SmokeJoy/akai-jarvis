const { spawn } = require('child_process');
const path = require('path');

const baseDir = path.resolve(__dirname, '..');
const jadxMcpBin = path.join(baseDir, 'tools', 'mcp', 'node_modules', '.bin', 'jadx-mcp.cmd');
const apkPath = path.join(baseDir, 'scratch', 'raiplay_base.apk');
const jdkPath = path.join(baseDir, 'tools', 'jdk-17');
const jadxBinDir = path.join(baseDir, 'tools', 'jadx', 'bin');

const env = {
    ...process.env,
    JAVA_HOME: jdkPath,
    PATH: `${jdkPath}\\bin;${baseDir}\\tools\\nodejs;${jadxBinDir};${process.env.PATH}`
};

const proc = spawn(jadxMcpBin, ['--file', apkPath, '--transport', 'stdio'], { env, shell: true });

let buffer = '';

proc.stdout.on('data', data => {
    buffer += data.toString();
    const lines = buffer.split('\n');
    buffer = lines.pop();
    for (const line of lines) {
        if (!line.trim()) continue;
        try {
            const msg = JSON.parse(line.trim());
            if (msg.id === 1) {
                proc.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
                // Call tool get_method_by_name
                const callReq = {
                    jsonrpc: '2.0',
                    id: 2,
                    method: 'tools/call',
                    params: {
                        name: 'get_method_by_name',
                        arguments: {
                            class: 'it.rai.raiplay.androidtv.WebMessageBridgeInstaller',
                            method: 'install'
                        }
                    }
                };
                proc.stdin.write(JSON.stringify(callReq) + '\n');
            } else if (msg.id === 2) {
                console.log('=== REAL MCP CALL RESULT (get_method_by_name) ===');
                if (msg.result && msg.result.content) {
                    msg.result.content.forEach(c => console.log(c.text));
                } else {
                    console.log(JSON.stringify(msg.result, null, 2));
                }
                proc.kill();
                process.exit(0);
            }
        } catch (e) {
            // non-json line
        }
    }
});

proc.stdin.write(JSON.stringify({
    jsonrpc: '2.0',
    id: 1,
    method: 'initialize',
    params: {
        protocolVersion: '2024-11-05',
        capabilities: {},
        clientInfo: { name: 'Antigravity-Audit', version: '1.0' }
    }
}) + '\n');
