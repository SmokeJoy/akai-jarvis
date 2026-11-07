$res = Invoke-RestMethod -Uri 'https://ws75.aptoide.com/api/7/app/get/package_name=it.rainet.androidtv'
$res.nodes.versions.list | Select-Object id, name, vername, vercode, size | Format-Table -AutoSize
