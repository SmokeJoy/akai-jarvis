$jsonl = "C:\Users\danie\.gemini\antigravity\brain\301a5daf-4835-45b9-b7d1-86d5907a0c37\.system_generated\logs\transcript_full.jsonl"
Get-Content $jsonl | ForEach-Object {
    $obj = $_ | ConvertFrom-Json
    if ($obj.step_index -eq 5545) {
        $obj.content | Out-File -FilePath "scratch\step_5545.txt" -Encoding utf8
        Write-Host "Wrote step 5545 content to scratch\step_5545.txt"
    }
}
