Write-Output "=== 1. NODE.JS & NPM ==="
try {
    $nodeVer = & node -v 2>&1
    Write-Output "node: $nodeVer"
} catch {
    Write-Output "node: not found ($($_))"
}
try {
    $npmVer = & npm -v 2>&1
    Write-Output "npm: $npmVer"
} catch {
    Write-Output "npm: not found ($($_))"
}
try {
    $npxVer = & npx -v 2>&1
    Write-Output "npx: $npxVer"
} catch {
    Write-Output "npx: not found ($($_))"
}

Write-Output "`n=== 2. JAVA & JDK ==="
try {
    $javaVer = & java -version 2>&1
    Write-Output "java: $javaVer"
} catch {
    Write-Output "java: not found ($($_))"
}
Write-Output "JAVA_HOME: $env:JAVA_HOME"

Write-Output "`n=== 3. SEARCHING FOR NODE, JAVA, GHIDRA, JADX ==="
$searchPaths = @(
    "C:\Program Files\Java",
    "C:\Program Files\Eclipse Adoptium",
    "C:\Program Files\Amazon Corretto",
    "C:\Program Files\Zulu",
    "C:\Program Files\nodejs",
    "C:\Program Files (x86)\nodejs",
    "$env:LOCALAPPDATA\Programs",
    "$env:LOCALAPPDATA\Microsoft\WinGet\Packages",
    "C:\tools",
    "C:\ghidra",
    "C:\jadx"
)
foreach ($p in $searchPaths) {
    if (Test-Path $p) {
        Write-Output "Found directory: $p"
        Get-ChildItem $p -Depth 1 | Select-Object -ExpandProperty Name | ForEach-Object { Write-Output "   - $_" }
    }
}

Write-Output "`n=== 4. ANTIGRAVITY CONFIG & MCP CONFIG FILES ==="
$mcpFiles = Get-ChildItem -Path "$env:USERPROFILE\.gemini\antigravity" -Filter "*mcp*" -Recurse -ErrorAction SilentlyContinue
if ($mcpFiles) {
    $mcpFiles | ForEach-Object { Write-Output "MCP config file: $($_.FullName)" }
} else {
    Write-Output "No *mcp* files found in .gemini/antigravity"
}

$settingsFiles = Get-ChildItem -Path "$env:USERPROFILE\.gemini\antigravity" -Filter "*.json" -Depth 2 -ErrorAction SilentlyContinue
$settingsFiles | ForEach-Object { Write-Output "JSON config: $($_.FullName)" }
