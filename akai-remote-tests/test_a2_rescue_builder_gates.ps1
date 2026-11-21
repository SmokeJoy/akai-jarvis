# ==============================================================================
# AKAI Custom TV - Gate Negativi Builder A2 Rescue (Script 15)
# Verifica off-device/CI che 15_build_jarvis_a2_rescue.ps1 rifiuti:
# - Override -ExpectedA2SourceSha verso un commit diverso dall'allowlist 6a6dd5d
# - RescueVersionCode <= TargetToRecoverVersionCode
# - RescueVersionName con diagnostic/debug o privo di tag a2-rescue
# - Keystore dentro il repo Git (anche tramite junction Windows / symlink Linux)
# - Passphrase di firma assenti
# Zero keystore owner reali, zero build binari o comandi ADB.
# ==============================================================================

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$script15 = Join-Path $repoRoot "scripts\15_build_jarvis_a2_rescue.ps1"
$psExe = (Get-Process -Id $PID).Path
$isWin = [Environment]::OSVersion.Platform -match "Win"

$workDir = Join-Path ([IO.Path]::GetTempPath()) ("akai_s15_gate_" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $workDir | Out-Null

$fakeKs = Join-Path $workDir "dummy.keystore"
[IO.File]::WriteAllText($fakeKs, "DUMMY_NOT_A_REAL_KEYSTORE")

$junctionPath = Join-Path $repoRoot ("_tmp_junc_s15_" + [Guid]::NewGuid().ToString("N"))
$extKeyDir = Join-Path $workDir "ext_ks_dir"
New-Item -ItemType Directory -Force -Path $extKeyDir | Out-Null
[IO.File]::WriteAllText((Join-Path $extKeyDir "linked.keystore"), "DUMMY_LINKED_KS")

$prevStore = $env:JARVIS_SIGNING_STOREPASS
$prevKey = $env:JARVIS_SIGNING_KEYPASS
$passed = 0
$failed = 0

function Invoke-Script15Gate([string[]]$ScriptArgs) {
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $psArgs = if ($isWin) { @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $script15) } else { @("-NoProfile", "-File", $script15) }
        $out = (& $psExe @psArgs @ScriptArgs 2>&1 | Out-String)
        $clean = ($out -replace '\x1b\[[0-9;]*m', '')
        $clean = ($clean -replace '(?m)^\s*\|\s*', ' ')
        $norm = ($clean -replace '\s+', ' ').Trim()
        return @{ ExitCode = $LASTEXITCODE; Raw = $out; Normalized = $norm }
    } finally {
        $ErrorActionPreference = $prevEap
    }
}

try {
    $env:JARVIS_SIGNING_STOREPASS = "dummy_gate_pass_123456"
    $env:JARVIS_SIGNING_KEYPASS = "dummy_gate_pass_123456"

    # 1. Reject overridden ExpectedA2SourceSha (even if valid 40-hex git commit in repo)
    $headSha = (& git -C $repoRoot rev-parse HEAD 2>&1 | Out-String).Trim()
    if ($headSha -notmatch "^[0-9a-fA-F]{40}$" -or $headSha -eq "6a6dd5d975518f422ba4aa947cd6063660d87729") {
        $headSha = "0000000000000000000000000000000000000000"
    }
    $r1 = Invoke-Script15Gate @("-ExpectedA2SourceSha", $headSha, "-SigningKeystorePath", $fakeKs, "-SigningAlias", "dummy")
    if ($r1.ExitCode -ne 0 -and $r1.Normalized -match "non presente nell'allowlist immutabile A2 approvata") {
        Write-Host "[PASS] Rescue Gate Test 1: Override ExpectedA2SourceSha bloccato dall'allowlist immutabile" -ForegroundColor Green
        $passed++
    } else {
        throw "Test 1 failed: exit=$($r1.ExitCode) out=$($r1.Normalized)"
    }

    # 2. Reject RescueVersionCode <= TargetToRecoverVersionCode
    $r2 = Invoke-Script15Gate @("-RescueVersionCode", "5", "-TargetToRecoverVersionCode", "5", "-SigningKeystorePath", $fakeKs, "-SigningAlias", "dummy")
    if ($r2.ExitCode -ne 0 -and $r2.Normalized -match "strettamente maggiore") {
        Write-Host "[PASS] Rescue Gate Test 2: RescueVersionCode <= TargetToRecoverVersionCode bloccato" -ForegroundColor Green
        $passed++
    } else {
        throw "Test 2 failed: exit=$($r2.ExitCode) out=$($r2.Normalized)"
    }

    # 3. Reject diagnostic / non-a2-rescue VersionName
    $r3a = Invoke-Script15Gate @("-RescueVersionName", "1.2.0-diagnostic-a2-rescue", "-SigningKeystorePath", $fakeKs, "-SigningAlias", "dummy")
    $r3b = Invoke-Script15Gate @("-RescueVersionName", "1.2.0-plain-v5", "-SigningKeystorePath", $fakeKs, "-SigningAlias", "dummy")
    if ($r3a.ExitCode -ne 0 -and $r3a.Normalized -match "non puo' contenere tag diagnostic/debug" -and $r3b.ExitCode -ne 0 -and $r3b.Normalized -match "deve contenere il tag riconoscibile 'a2-rescue'") {
        Write-Host "[PASS] Rescue Gate Test 3: VersionName diagnostico o senza tag a2-rescue bloccato" -ForegroundColor Green
        $passed++
    } else {
        throw "Test 3 failed: a=$($r3a.Normalized) b=$($r3b.Normalized)"
    }

    # 4. Reject keystore inside repo (lexical + real junction/symlink outside->inside or inside->outside check)
    $lexicalRepoKs = Join-Path $repoRoot "_tmp_forbidden_ks.jks"
    try {
        [IO.File]::WriteAllText($lexicalRepoKs, "DUMMY")
        $r4a = Invoke-Script15Gate @("-SigningKeystorePath", $lexicalRepoKs, "-SigningAlias", "dummy")
        if ($r4a.ExitCode -eq 0 -or $r4a.Normalized -notmatch "dentro il repository Git") {
            throw "Test 4a lexical failed: $($r4a.Normalized)"
        }
    } finally {
        Remove-Item -LiteralPath $lexicalRepoKs -Force -ErrorAction SilentlyContinue
    }

    # Junction/symlink outside repo pointing INTO repo
    $juncOutToRepo = Join-Path $workDir "link_to_repo"
    if ($isWin) {
        $mkOut = (& cmd.exe /c mklink /J "`"$juncOutToRepo`"" "`"$repoRoot`"" 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) { throw "mklink /J failed: $mkOut" }
    } else {
        & ln -s $repoRoot $juncOutToRepo
        if ($LASTEXITCODE -ne 0) { throw "ln -s failed" }
    }
    try {
        # Usa file reale esistente nel repo traversato dalla junction
        $ksThroughJunc = Join-Path $juncOutToRepo "akai-remote-tests\UnitTests.java"
        $r4b = Invoke-Script15Gate @("-SigningKeystorePath", $ksThroughJunc, "-SigningAlias", "dummy")
        if ($r4b.ExitCode -ne 0 -and $r4b.Normalized -match "dentro il repository Git") {
            Write-Host "[PASS] Rescue Gate Test 4: Keystore dentro repo (lessicale + junction/symlink) bloccato" -ForegroundColor Green
            $passed++
        } else {
            throw "Test 4b junction failed: exit=$($r4b.ExitCode) out=$($r4b.Normalized)"
        }
    } finally {
        if ($isWin -and (Test-Path -LiteralPath $juncOutToRepo)) {
            [IO.Directory]::Delete($juncOutToRepo, $false)
        } elseif (Test-Path -LiteralPath $juncOutToRepo) {
            Remove-Item -LiteralPath $juncOutToRepo -Force -ErrorAction SilentlyContinue
        }
    }

    # 5. Reject missing env passphrases
    Remove-Item Env:JARVIS_SIGNING_STOREPASS -ErrorAction SilentlyContinue
    Remove-Item Env:JARVIS_SIGNING_KEYPASS -ErrorAction SilentlyContinue
    $r5 = Invoke-Script15Gate @("-SigningKeystorePath", $fakeKs, "-SigningAlias", "dummy")
    if ($r5.ExitCode -ne 0 -and $r5.Normalized -match "JARVIS_SIGNING_STOREPASS") {
        Write-Host "[PASS] Rescue Gate Test 5: Variabili passphrase firma mancanti bloccate" -ForegroundColor Green
        $passed++
    } else {
        throw "Test 5 failed: exit=$($r5.ExitCode) out=$($r5.Normalized)"
    }
} catch {
    Write-Host "[FAIL] Errore Rescue Gate Tests: $($_.Exception.Message)" -ForegroundColor Red
    $failed++
} finally {
    if ($null -eq $prevStore) { Remove-Item Env:JARVIS_SIGNING_STOREPASS -ErrorAction SilentlyContinue } else { $env:JARVIS_SIGNING_STOREPASS = $prevStore }
    if ($null -eq $prevKey) { Remove-Item Env:JARVIS_SIGNING_KEYPASS -ErrorAction SilentlyContinue } else { $env:JARVIS_SIGNING_KEYPASS = $prevKey }
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "ESITO A2 RESCUE BUILDER GATE TESTS: PASS=$passed FAIL=$failed"
if ($failed -gt 0 -or $passed -ne 5) { exit 1 }
exit 0
