$gitDir = "C:\Users\danie\AppData\Local\Microsoft\WinGet\Packages\Git.MinGit_Microsoft.Winget.Source_8wekyb3d8bbwe\cmd"
$env:PATH = "$gitDir;$env:PATH"
$gh = "C:\Program Files\GitHub CLI\gh.exe"

Set-Location "c:\Users\danie\OneDrive\Documenti\Antygravity\Akay"

Write-Host "=== PR #1 REVIEWS ==="
& $gh api repos/SmokeJoy/akai-jarvis/pulls/1/reviews

Write-Host "`n=== PR #1 ISSUE COMMENTS ==="
& $gh api repos/SmokeJoy/akai-jarvis/issues/1/comments
