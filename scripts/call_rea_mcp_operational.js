const { spawn } = require('child_process');
const path = require('path');
const readline = require('readline');
const fs = require('fs');

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
            console.log("[REA MCP] Server initialized successfully:", JSON.stringify(msg.result.serverInfo));
            // Call operational tool
            const toolCall = {
                jsonrpc: '2.0',
                id: 2,
                method: 'tools/call',
                params: {
                    name: 'inspect_analysis_settings',
                    arguments: {
                        settings: [
                            'jadx.operation_timeout_ms',
                            'ghidra.decompile_timeout_seconds',
                            'wasm.command_timeout_ms'
                        ]
                    }
                }
            };
            console.log("[REA MCP] Executing real tool call:", toolCall.params.name);
            send(toolCall);
        } else if (msg.id === 2) {
            console.log("[REA MCP] Tool execution response received!");
            console.log("[REA MCP] Result content:", JSON.stringify(msg.result, null, 2));
            fs.writeFileSync('scratch/rea_mcp_call_result.json', JSON.stringify(msg.result, null, 2));
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
