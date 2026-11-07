const { spawn } = require('child_process');
const path = require('path');

const baseDir = path.resolve(__dirname, '..');
const nodeBin = path.join(baseDir, 'tools', 'nodejs', 'node.exe');
const reaScript = path.join(baseDir, 'tools', 'mcp', 'node_modules', 'rea-agents', 'scripts', 'rea.mjs');

console.log('Spawning REA MCP stdio server...');
const proc = spawn(nodeBin, [reaScript, '--mcp'], {
    env: { ...process.env, PATH: `${path.join(baseDir, 'tools', 'nodejs')};${process.env.PATH}` }
});

let buffer = '';

proc.stdout.on('data', data => {
    buffer += data.toString();
    const lines = buffer.split('\n');
    buffer = lines.pop();
    for (const line of lines) {
        if (!line.trim()) continue;
        try {
            const msg = JSON.parse(line.trim());
            console.log('REA MCP Response [id=' + msg.id + ']:', msg.result ? (msg.result.tools ? `Found ${msg.result.tools.length} tools` : msg.result) : msg);
            if (msg.id === 1) {
                proc.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
                proc.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'tools/list', params: {} }) + '\n');
            } else if (msg.id === 2) {
                console.log('=== REA MCP SERVER READY ===');
                if (msg.result && msg.result.tools) {
                    console.log(`Available REA tools (${msg.result.tools.length}):`);
                    msg.result.tools.slice(0, 10).forEach(t => console.log(`  * ${t.name}`));
                }
                proc.kill();
                process.exit(0);
            }
        } catch (e) {
            console.log('REA stdout:', line);
        }
    }
});

proc.stderr.on('data', data => {
    // console.error('REA stderr:', data.toString().trim());
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
