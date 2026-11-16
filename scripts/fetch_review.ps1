$gh = "C:\Program Files\GitHub CLI\gh.exe"
$comment = & $gh api repos/SmokeJoy/akai-jarvis/issues/comments/6713745676 | ConvertFrom-Json
$comment.body | Out-File -Encoding utf8 "scripts/last_review.md"
Write-Host "Comment written to scripts/last_review.md"
