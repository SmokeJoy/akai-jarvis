$base = (Resolve-Path "$PSScriptRoot\..").Path
$env:JAVA_HOME = "$base\tools\jdk-17"
$env:NODE_PATH = "$base\tools\nodejs"
$env:PATH = "$base\tools\jdk-17\bin;$base\tools\nodejs;$base\tools\jadx\bin;$env:PATH"

function Invoke-Jadx {
    param([string[]]$JadxArgs)
    & "$base\tools\jadx\bin\jadx.bat" @JadxArgs
}

function Invoke-Node {
    param([string[]]$NodeArgs)
    & "$base\tools\nodejs\node.exe" @NodeArgs
}

function Invoke-Npm {
    param([string[]]$NpmArgs)
    & "$base\tools\nodejs\npm.cmd" @NpmArgs
}
