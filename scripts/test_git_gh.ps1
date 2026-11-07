$git = "C:\Users\danie\AppData\Local\Microsoft\WinGet\Packages\Git.MinGit_Microsoft.Winget.Source_8wekyb3d8bbwe\cmd\git.exe"
$gh = "C:\Program Files\GitHub CLI\gh.exe"

Write-Host "Git version:"
& $git --version

Write-Host "GitHub CLI auth status:"
& $gh auth status

Write-Host "GitHub Repositories for SmokeJoy:"
& $gh repo list SmokeJoy --limit 15
