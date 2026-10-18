# Funciones para el qBittorrent nativo de Windows (spec 013). Las usan
# start/stop/restart/status.ps1. Si la tarea programada no existe
# (qBittorrent en Docker, sin docker-compose.override.yml), no hacen nada.

$QbtTask = 'MediaCenter qBittorrent'

function Get-QbtEnv([string]$name, [string]$default) {
    $envFile = Join-Path (Split-Path -Parent $PSScriptRoot) '.env'
    $line = Get-Content $envFile -ErrorAction SilentlyContinue | Where-Object { $_ -match "^$name=" } | Select-Object -First 1
    if ($line) { (($line -split '=', 2)[1]).Trim("'", '"') } else { $default }
}

function Get-QbtPass { Get-QbtEnv 'QBT_PASS' 'adminadmin' }

# El instalador elige otro puerto si el 8080 estaba ocupado (QBT_URL en .env)
$QbtPort = if ((Get-QbtEnv 'QBT_URL' '') -match ':(\d+)/?$') { $Matches[1] } else { '8080' }
$QbtUrl = "http://127.0.0.1:$QbtPort"

function Test-QbtNativo {
    [bool](Get-ScheduledTask -TaskName $QbtTask -ErrorAction SilentlyContinue)
}

function Get-QbtNativoProceso {
    Get-CimInstance Win32_Process -Filter "Name='qbittorrent.exe'" |
        Where-Object { $_.CommandLine -match 'qbittorrent-nativo' }
}

function Start-QbtNativo {
    if (-not (Test-QbtNativo)) { return }
    if (Get-QbtNativoProceso) { Write-Host 'qBittorrent (Windows) ya estaba en marcha.'; return }
    Start-ScheduledTask -TaskName $QbtTask
    Write-Host 'qBittorrent (Windows) arrancado.'
}

function Stop-QbtNativo {
    if (-not (Test-QbtNativo)) { return }
    if (-not (Get-QbtNativoProceso)) { Write-Host 'qBittorrent (Windows) ya estaba parado.'; return }
    # Cierre ordenado por su API (guarda el estado de los torrents); la X
    # de la ventana solo lo manda a la bandeja.
    try {
        $s = New-Object Microsoft.PowerShell.Commands.WebRequestSession
        Invoke-WebRequest -UseBasicParsing -WebSession $s -Method Post -TimeoutSec 10 `
            -Body @{ username = (Get-QbtEnv 'QBT_USER' 'admin'); password = (Get-QbtPass) } "$QbtUrl/api/v2/auth/login" | Out-Null
        Invoke-WebRequest -UseBasicParsing -WebSession $s -Method Post -TimeoutSec 10 "$QbtUrl/api/v2/app/shutdown" | Out-Null
    } catch {
        Write-Warning "qBittorrent (Windows) no responde a su API: $($_.Exception.Message)"
    }
    for ($i = 0; $i -lt 30 -and (Get-QbtNativoProceso); $i++) { Start-Sleep 1 }
    if (Get-QbtNativoProceso) { Write-Warning 'qBittorrent (Windows) sigue abierto: ciérralo desde su icono de la bandeja (Salir).' }
    else { Write-Host 'qBittorrent (Windows) parado.' }
}

$QbtPanelTask = 'MediaCenter qBittorrent (panel)'

function Register-QbtPanelTask {
    # Tarea que abre qBittorrent cuando el panel lo pide (spec 030): cada
    # minuto ejecuta qbt-abrir.cmd, oculto con conhost --headless (sin
    # ventana), y termina en milisegundos. Solo con la sesion iniciada.
    param([Parameter(Mandatory)] [string] $ConfigRoot)
    $cmd = Join-Path $PSScriptRoot 'qbt-abrir.cmd'
    $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\conhost.exe" `
        -Argument "--headless `"$env:SystemRoot\System32\cmd.exe`" /c `"`"$cmd`" `"$ConfigRoot`"`""
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $QbtPanelTask -Action $action -Trigger $trigger -Settings $settings -Force `
        -Description 'Abre el qBittorrent del MediaCenter si se pide desde el panel (spec 030).' | Out-Null
}

function Show-QbtNativo {
    if (-not (Test-QbtNativo)) { return }
    $p = Get-QbtNativoProceso
    $web = try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 "$QbtUrl/" | Out-Null; 'responde' } catch { if ($_.Exception.Response) { 'responde' } else { 'NO responde' } }
    if ($p) { Write-Host "qBittorrent (Windows): en marcha (pid $($p.ProcessId)), web en :$QbtPort $web" }
    else { Write-Host 'qBittorrent (Windows): PARADO (arráncalo con scripts\start.ps1)' }
}
