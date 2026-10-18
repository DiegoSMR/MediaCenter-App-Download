<#
.SYNOPSIS
Cambia el perfil de consumo de recursos del stack (Minimo/Default/Rendimiento).

.DESCRIPTION
Aplica en caliente los limites de qBittorrent (velocidad de subida en
seeding, descargas/subidas activas, hilos de hashing) via su API, y
deja preparado el cambio de techo de memoria de WSL2 en .wslconfig
-- ese ultimo requiere "wsl --shutdown" (para todo el stack unos
segundos), asi que el script NO lo hace solo: avisa y lo deja a mano.

Ver development/specs/016-selector-modos-recursos.md.

.EXAMPLE
scripts\set-mode.ps1 -Mode Minimo
scripts\set-mode.ps1 -Mode Rendimiento
#>
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Minimo", "Default", "Rendimiento")]
    [string]$Mode
)

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$envFile = Join-Path $ProjectRoot ".env"

# --- 1. Leer .env (CONFIG_ROOT) -------------------------------------------
$envVars = @{}
if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        if ($_ -match '^\s*([A-Z_]+)\s*=\s*(.*)\s*$') {
            $envVars[$matches[1]] = $matches[2]
        }
    }
}
$configRoot = $envVars["CONFIG_ROOT"]
if (-not $configRoot) {
    Write-Warning "No se encontro CONFIG_ROOT en .env -- no se guardara el modo activo."
}

# --- 2. Valores por perfil (ver tabla en la spec 016) ----------------------
$profiles = @{
    "Minimo" = @{
        WslMemoryGB       = 4
        QbtUpLimitKBs     = 512
        MaxActiveDownloads = 2
        MaxActiveUploads   = 2
        HashingThreads     = 1
    }
    "Default" = @{
        WslMemoryGB       = 6
        QbtUpLimitKBs     = 2048
        MaxActiveDownloads = 5
        MaxActiveUploads   = 5
        HashingThreads     = 4
    }
    "Rendimiento" = @{
        WslMemoryGB       = 12
        QbtUpLimitKBs     = 0   # 0 = sin limite en la API de qBittorrent
        MaxActiveDownloads = 10
        MaxActiveUploads   = 10
        HashingThreads     = 8
    }
}
$p = $profiles[$Mode]

Write-Output "=== Aplicando modo '$Mode' ==="

# --- 3. qBittorrent, en caliente vía su API --------------------------------
$qbtUser = "admin"
$qbtPass = "adminadmin"   # si la cambiaste tras el primer login, actualizala aqui
$loginUri = "http://localhost:8080/api/v2/auth/login"
$prefsUri = "http://localhost:8080/api/v2/app/setPreferences"

try {
    $session = @{}
    $loginResp = Invoke-WebRequest -Uri $loginUri -Method Post -Body @{ username = $qbtUser; password = $qbtPass } -SessionVariable qbtSession -UseBasicParsing
    if ($loginResp.Content -ne "Ok.") {
        throw "Login en qBittorrent fallo -- revisa usuario/password en este script si la cambiaste."
    }

    $upLimitBytes = $p.QbtUpLimitKBs * 1024
    $json = @{
        up_limit           = $upLimitBytes
        max_active_downloads = $p.MaxActiveDownloads
        max_active_uploads   = $p.MaxActiveUploads
        max_active_torrents  = $p.MaxActiveDownloads + $p.MaxActiveUploads
        hashing_threads      = $p.HashingThreads
    } | ConvertTo-Json -Compress

    Invoke-WebRequest -Uri $prefsUri -Method Post -Body @{ json = $json } -WebSession $qbtSession -UseBasicParsing | Out-Null

    $limitDesc = if ($p.QbtUpLimitKBs -eq 0) { "sin limite" } else { "$($p.QbtUpLimitKBs) KB/s" }
    Write-Output "qBittorrent: subida=$limitDesc, descargas activas=$($p.MaxActiveDownloads), subidas activas=$($p.MaxActiveUploads), hashing_threads=$($p.HashingThreads)"
} catch {
    Write-Warning "No se pudo aplicar la configuracion de qBittorrent: $_"
    Write-Warning "Comprueba que el stack esta arrancado (scripts\status.ps1) y que localhost:8080 responde."
}

# --- 4. .wslconfig: se prepara, no se aplica solo (requiere wsl --shutdown) -
$wslConfigPath = Join-Path $env:USERPROFILE ".wslconfig"
$targetMemory = "$($p.WslMemoryGB)GB"
$currentMemory = $null

if (Test-Path $wslConfigPath) {
    $content = Get-Content $wslConfigPath -Raw
    if ($content -match 'memory\s*=\s*(\S+)') {
        $currentMemory = $matches[1]
    }
} else {
    $content = "[wsl2]`nautoMemoryReclaim=gradual`n"
}

if ($currentMemory -eq $targetMemory) {
    Write-Output ".wslconfig: memory=$targetMemory ya estaba puesto, no hace falta reiniciar WSL2."
} else {
    if ($content -match 'memory\s*=\s*\S+') {
        $newContent = $content -replace 'memory\s*=\s*\S+', "memory=$targetMemory"
    } else {
        $newContent = $content.TrimEnd() + "`nmemory=$targetMemory`n"
    }
    Set-Content -Path $wslConfigPath -Value $newContent -Encoding utf8
    Write-Output ".wslconfig actualizado: memory=$targetMemory (antes: $currentMemory)"
    Write-Warning "Para que el nuevo techo de memoria se aplique hace falta 'wsl --shutdown' -- esto para TODO el stack unos segundos. Ejecutalo tu cuando te venga bien; luego Docker Desktop se recupera solo (puede necesitar que lo reabras si no arranca en 1-2 min)."
}

# --- 5. Guardar el modo activo ----------------------------------------------
if ($configRoot) {
    try {
        Set-Content -Path (Join-Path $configRoot ".active-mode") -Value $Mode -Encoding ascii
    } catch {
        Write-Warning "No se pudo guardar el modo activo en ${configRoot}: $_"
    }
}

Write-Output "=== Modo '$Mode' aplicado ==="
