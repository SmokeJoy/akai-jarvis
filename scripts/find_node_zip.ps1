$url = "https://nodejs.org/dist/latest-v22.x/"
$html = Invoke-WebRequest -Uri $url -UseBasicParsing
$match = [regex]::Match($html.Content, 'node-v22\.[0-9\.]+-win-x64\.zip')
if ($match.Success) {
    Write-Output "Found Node 22 zip: $($match.Value)"
    $fullUrl = "https://nodejs.org/dist/latest-v22.x/$($match.Value)"
    Write-Output "Full URL: $fullUrl"
} else {
    Write-Output "Node 22 zip not found in index"
}
