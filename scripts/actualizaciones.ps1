# Actualizaciones de las apps (spec 042): mira que imagenes tienen version
# nueva en su registro y, si se pide, las actualiza. Corre en Windows, no en
# un contenedor: asi ninguno necesita docker.sock.
#
#   scripts\actualizaciones.ps1              lista lo que tiene version nueva
#   scripts\actualizaciones.ps1 -Actualizar  copia de seguridad + actualiza
#   scripts\actualizaciones.ps1 -Lanzar <CONFIG_ROOT>
#       lo usa scripts\qbt-abrir.cmd (tarea de cada minuto) si ve un aviso
#       del panel. Esa tarea se corta al minuto, y buscar o actualizar tarda
#       mas: este modo (re)crea la tarea "MediaCenter actualizaciones", sin
#       limite de tiempo, y la lanza.
#   scripts\actualizaciones.ps1 -DesdePanel <CONFIG_ROOT>
#       lo que corre esa tarea: segun el aviso (<CONFIG_ROOT>\disk-report\
#       actualizar o buscar-actualizaciones) actualiza o solo busca, y deja
#       el resultado en actualizaciones.json para el panel.
param([switch]$Actualizar, [string]$Lanzar, [string]$DesdePanel)

# Sin ErrorActionPreference=Stop: en PowerShell 5.1 convertiria en error
# cualquier linea de docker por stderr. UTF-8 para leer bien su salida.
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$TaskName = 'MediaCenter actualizaciones'

if ($Lanzar) {
    # Se registra cada vez (-Force): si el repo cambia de sitio, la tarea
    # sigue apuntando bien. Un usuario normal puede crear tareas para si.
    $who = "$env:USERDOMAIN\$env:USERNAME"
    $arg = "--headless `"$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe`" -NoProfile -ExecutionPolicy Bypass " +
           "-File `"$PSCommandPath`" -DesdePanel `"$Lanzar`""
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $TaskName -Force -Settings $settings `
        -Principal (New-ScheduledTaskPrincipal -UserId $who -LogonType Interactive -RunLevel Limited) `
        -Action (New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\conhost.exe" -Argument $arg) | Out-Null
    Start-ScheduledTask -TaskName $TaskName
    return
}

if ($DesdePanel) {
    $stateDir = Join-Path $DesdePanel 'disk-report'
    $resultFile = Join-Path $stateDir 'actualizaciones.json'
    $flagUpdate = Join-Path $stateDir 'actualizar'
    $flagCheck = Join-Path $stateDir 'buscar-actualizaciones'
    if (Test-Path -LiteralPath $flagUpdate) {
        $running = "$flagUpdate.en-curso"
        Move-Item -LiteralPath $flagUpdate -Destination $running -Force
        Remove-Item -LiteralPath $flagCheck -Force -ErrorAction SilentlyContinue  # se busca al final igualmente
        $Actualizar = $true
    } elseif (Test-Path -LiteralPath $flagCheck) {
        $running = "$flagCheck.en-curso"
        Move-Item -LiteralPath $flagCheck -Destination $running -Force
    } else {
        return  # nada pedido
    }
}

function Get-Epoch { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

# Servicios activos con imagen de registro (los que se construyen aqui,
# como bootstrap o disk-report, no). Por cada uno: version nueva en el
# registro (digest distinto del descargado) o contenedor con una imagen mas
# vieja que la ya descargada (falta recrearlo).
function Get-Updates {
    $found = @(); $errors = @()
    $cfg = (docker compose config --format json 2>$null | Out-String) | ConvertFrom-Json
    if (-not $cfg) { return @{ updates = @(); errors = @('Docker no responde (¿está abierto Docker Desktop?)') } }
    foreach ($p in $cfg.services.PSObject.Properties) {
        $s = $p.Value
        if ($s.build -or -not $s.image) { continue }
        $img = $s.image
        $remote = (docker buildx imagetools inspect $img --format '{{json .Manifest}}' 2>$null | Out-String)
        $digest = if ($remote.Trim()) { ($remote | ConvertFrom-Json).digest } else { $null }
        if (-not $digest) { $errors += "$($p.Name): no se pudo consultar $img"; continue }
        $local = @(docker image inspect $img --format '{{range .RepoDigests}}{{println .}}{{end}}' 2>$null) | Where-Object { $_ }
        $new = -not ($local | Where-Object { $_.EndsWith("@$digest") })
        $stale = $false
        $cid = docker compose ps -a -q $p.Name 2>$null | Select-Object -First 1
        if ($cid -and -not $new) {
            $stale = (docker inspect $cid --format '{{.Image}}' 2>$null) -ne (docker image inspect $img --format '{{.Id}}' 2>$null)
        }
        if ($new -or $stale) { $found += @{ service = $p.Name; image = $img; downloaded = [bool]$stale } }
    }
    @{ updates = $found; errors = $errors }
}

Push-Location $ProjectRoot
try {
    $last = $null
    if ($Actualizar) {
        $before = Get-Updates
        $svcs = @($before.updates | ForEach-Object { $_.service })
        if (-not $svcs.Count) {
            $last = @{ at = (Get-Epoch); ok = (-not $before.errors.Count); services = @();
                       message = $(if ($before.errors.Count) { $before.errors -join '; ' } else { 'Ya estaba todo al día.' }) }
        } else {
            # Copia de la configuracion justo antes: backup copia al arrancar.
            Write-Host 'Copia de seguridad de la configuración...'
            $since = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            docker compose restart backup 2>$null | Out-Null
            $backupOk = $false
            for ($i = 0; $i -lt 120; $i++) {  # hasta 10 min
                if ((docker compose logs --since $since backup 2>$null | Out-String) -match 'Backup completado') { $backupOk = $true; break }
                Start-Sleep -Seconds 5
            }
            if (-not $backupOk) {
                $last = @{ at = (Get-Epoch); ok = $false; services = $svcs;
                           message = 'No se ha actualizado: la copia de seguridad no ha terminado (mira "docker compose logs backup").' }
            } else {
                Write-Host "Actualizando: $($svcs -join ', ')"
                $env:COMPOSE_PARALLEL_LIMIT = '3'   # lscr.io corta las descargas en paralelo (spec 039)
                docker compose pull @svcs 2>$null | Out-Null
                $pullOk = $LASTEXITCODE -eq 0
                # Solo esos servicios: no arranca lo que alguien haya parado
                # ni relanza bootstrap.
                docker compose up -d @svcs 2>$null | Out-Null
                $upOk = $LASTEXITCODE -eq 0
                $last = @{ at = (Get-Epoch); ok = ($pullOk -and $upOk); services = $svcs;
                           message = $(if ($pullOk -and $upOk) { "Actualizado: $($svcs -join ', ')." }
                                       elseif (-not $pullOk) { 'Falló la descarga de alguna imagen; se reintentará la próxima vez.' }
                                       else { 'Imágenes descargadas, pero falló al recrear algún contenedor (docker compose ps).' }) }
            }
        }
        Write-Host $last.message
    }

    $r = Get-Updates
    if ($DesdePanel) {
        # Conserva el resultado de la ultima actualizacion entre busquedas.
        if (-not $last -and (Test-Path -LiteralPath $resultFile)) {
            try { $last = (Get-Content -LiteralPath $resultFile -Raw -Encoding UTF8 | ConvertFrom-Json).last_update } catch { }
        }
        $out = @{ checked_at = (Get-Epoch); updates = @($r.updates); errors = @($r.errors); last_update = $last }
        # UTF-8 sin BOM (Set-Content de PowerShell 5.1 pondria ANSI).
        [IO.File]::WriteAllText($resultFile, ($out | ConvertTo-Json -Compress -Depth 5), (New-Object Text.UTF8Encoding $false))
    } else {
        if ($r.updates.Count) {
            Write-Host 'Con versión nueva:'
            $r.updates | ForEach-Object { Write-Host "  $($_.service)  ($($_.image))$(if ($_.downloaded) { ' - ya descargada, falta recrearlo' })" }
            if (-not $Actualizar) { Write-Host 'Para actualizar: scripts\actualizaciones.ps1 -Actualizar' }
        } else {
            Write-Host 'Todo al día.'
        }
        $r.errors | ForEach-Object { Write-Host "AVISO: $_" }
    }
} finally {
    Pop-Location
    if ($DesdePanel -and $running) { Remove-Item -LiteralPath $running -Force -ErrorAction SilentlyContinue }
}
