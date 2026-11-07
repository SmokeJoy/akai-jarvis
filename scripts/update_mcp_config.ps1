$base = (Resolve-Path "$PSScriptRoot\..").Path
$configPath = "$env:USERPROFILE\.gemini\config\mcp_config.json"

$nodeExe = "$base\tools\nodejs\node.exe"
$jadxCmd = "$base\tools\mcp\node_modules\.bin\jadx-mcp.cmd"
$reaScript = "$base\tools\mcp\node_modules\rea-agents\scripts\rea.mjs"
$defaultApk = "$base\scratch\raiplay_base.apk"
$jdkPath = "$base\tools\jdk-17"

$config = @{
    mcpServers = @{
        "jadx" = @{
            command = $jadxCmd
            args = @(
                "--file",
                $defaultApk,
                "--transport",
                "stdio"
            )
            env = @{
                "JAVA_HOME" = $jdkPath
            }
        }
        "rea" = @{
            command = $nodeExe
            args = @(
                $reaScript,
                "--mcp"
            )
        }
    }
}

$json = $config | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText($configPath, $json)
Write-Host "Updated $configPath successfully!" -ForegroundColor Green
Get-Content $configPath
