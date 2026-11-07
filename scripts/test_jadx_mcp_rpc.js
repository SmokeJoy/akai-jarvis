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

console.log('Spawning jadx-mcp with input:', apkPath);
const proc = spawn(jadxMcpBin, ['--file', apkPath, '--transport', 'stdio'], { env, shell: true });

let buffer = '';

proc.stdout.on('data', data => {
    buffer += data.toString();
    const lines = buffer.split('\n');
    buffer = lines.pop(); // keep last incomplete line
    for (const line of lines) {
        if (!line.trim()) continue;
        try {
            const msg = JSON.parse(line.trim());
            console.log('MCP Response [id=' + msg.id + ']:', msg.result ? (msg.result.tools ? `Found ${msg.result.tools.length} tools` : msg.result) : msg);
            if (msg.id === 1) {
                // Send initialized notification and tools/list
                proc.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
                proc.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'tools/list', params: {} }) + '\n');
            } else if (msg.id === 2) {
                if (msg.result && msg.result.tools) {
                    console.log('Available tools in jadx-mcp:');
                    msg.result.tools.forEach(t => console.log(`  * ${t.name}: ${t.description}`));
                }
                proc.kill();
                process.exit(0);
            }
        } catch (e) {
            console.log('jadx-mcp stdout:', line);
        }
    }
});

proc.stderr.on('data', data => {
    console.error('jadx-mcp stderr:', data.toString().trim());
});

proc.on('close', code => {
    console.log('jadx-mcp exited with code:', code);
});

// Send initialize request
const initReq = {
    jsonrpc: '2.0',
    id: 1,
    method: 'initialize',
    params: {
        protocolVersion: '2024-11-05',
        capabilities: {},
        clientInfo: { name: 'Antigravity-Audit', version: '1.0' }
    }
};

proc.stdin.write(JSON.stringify(initReq) + '\n');
