$cands = @(
    "c:\Users\danie\OneDrive\Documenti\Antygravity\Akay\AKAI_JARVIS_v16_PACCHETTO_AUDIT_CHATGPT.zip",
    "c:\Users\danie\Downloads\AKAI_JARVIS_v16_PACCHETTO_AUDIT_CHATGPT.zip",
    "c:\Users\danie\Downloads\*.zip"
)

foreach ($c in $cands) {
    Get-ChildItem $c -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host "FOUND: $($_.FullName) ($($_.Length) bytes)"
    }
}
