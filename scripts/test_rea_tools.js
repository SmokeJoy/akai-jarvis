const { spawn } = require('child_process');
const path = require('path');
const readline = require('readline');

const nodeExe = path.resolve(__dirname, '..', 'tools', 'nodejs', 'node.exe');
const reaScript = path.resolve(__dirname, '..', 'tools', 'mcp', 'node_modules', 'rea-agents', 'scripts', 'rea.mjs');

const p = spawn(nodeExe, [reaScript, '--mcp'], {
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
            console.log("REA MCP initialized.");
            send({ jsonrpc: '2.0', id: 2, method: 'tools/list', params: {} });
        } else if (msg.id === 2) {
            const toolNames = msg.result.tools.map(t => t.name);
            console.log(`Total REA tools: ${toolNames.length}`);
            console.log("Sample tool names:", toolNames.slice(0, 30));
            // Let's call an operational REA tool, e.g. read_file or grep or analyze
            const targetTool = toolNames.find(t => t.includes('file') || t.includes('search') || t.includes('grep') || t.includes('inspect') || t.includes('echo')) || toolNames[0];
            console.log("Invoking REA tool:", targetTool);
            const toolDef = msg.result.tools.find(t => t.name === targetTool);
            console.log("Tool schema:", JSON.stringify(toolDef.inputSchema, null, 2));

            p.kill();
            process.exit(0);
        }
    } catch (e) {
        console.error("Parse error:", e);
    }
});

p.stderr.on('data', d => console.error("REA STDERR:", d.toString()));

send({
    jsonrpc: '2.0',
    id: 1,
    method: 'initialize',
    params: {
        protocolVersion: '2024-11-05',
        clientInfo: { name: 'antigravity-rea-client', version: '1.0' },
        capabilities: {}
    }
});
