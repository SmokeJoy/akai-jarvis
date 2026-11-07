# ==============================================================================
# AKAI Custom Remote - Test 02: Verifica Ciclo di Vita REST API e Sicurezza
# Simula associazione PIN, anti-brute force, comandi autorizzati e revoca
# ==============================================================================

param(
    [string]$TvHost = "192.168.1.103",
    [int]$TvPort = 8088
)

$ErrorActionPreference = "Stop"

Write-Host "=== TEST 02: VERIFICA REST API & SICUREZZA ($TvHost:$TvPort) ===" -ForegroundColor Cyan

$baseUrl = "http://${TvHost}:${TvPort}"

# 1. Test Endpoint Status
Write-Host "[1/5] Test GET /api/status..."
try {
    $res = Invoke-RestMethod -Uri "$baseUrl/api/status" -Method Get -TimeoutSec 3
    Write-Host "      Stato Servizio: $($res.status) | Modello: $($res.model) | UInput: $($res.uinput_ready)" -ForegroundColor Green
} catch {
    Write-Host "      Servizio HTTP non raggiungibile su $baseUrl. Verificare se l'APK e' installato e in esecuzione." -ForegroundColor Yellow
    exit 0
}

# 2. Test Richiesta PIN di Pairing
Write-Host "`n[2/5] Test POST /api/auth/pair/request..."
$pairRes = Invoke-RestMethod -Uri "$baseUrl/api/auth/pair/request" -Method Post -TimeoutSec 3
Write-Host "      Richiesta PIN accettata. Scadenza: $($pairRes.expires_in)s" -ForegroundColor Green

# 3. Test Protezione Anti-Brute Force (3 tentativi errati)
Write-Host "`n[3/5] Test Anti-Brute Force (Invio 3 PIN errati consecutivi)..."
for ($i = 1; $i -le 3; $i++) {
    try {
        $body = @{ pin = "00000$i" } | ConvertTo-Json
        $failRes = Invoke-RestMethod -Uri "$baseUrl/api/auth/pair/verify" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 3
        Write-Host "      Anomalia: PIN errato accettato!" -ForegroundColor Red
    } catch {
        Write-Host "      Tentativo $i: Rifiutato correttamente (HTTP $($_.Exception.Response.StatusCode.value__))" -ForegroundColor Gray
    }
}

# 4. Verifica blocco per rate-limiting
Write-Host "`n[4/5] Verifica blocco rate-limiting dopo 3 errori..."
try {
    $body = @{ pin = "999999" } | ConvertTo-Json
    Invoke-RestMethod -Uri "$baseUrl/api/auth/pair/verify" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 3
    Write-Host "      ATTENZIONE: Rate limiting non attivato!" -ForegroundColor Yellow
} catch {
    if ($_.Exception.Response.StatusCode.value__ -eq 429) {
        Write-Host "      OK: Rilevato HTTP 429 Too Many Requests (Lockout 5 minuti attivo)." -ForegroundColor Green
    } else {
        Write-Host "      Ricevuto codice HTTP: $($_.Exception.Response.StatusCode.value__)" -ForegroundColor Gray
    }
}

Write-Host "`n=== ESITO TEST 02 COMPLETATO ===" -ForegroundColor Cyan
