# Actualiza MediaCenter mismo (spec 051): bootstrap, panel, scripts,
# docker-compose.yml... desde el repo publico DiegoSMR/MediaCenter-App-Download
# (lo publica installer-exe\publicar.ps1). Las apps (Radarr, Jellyfin...) las
# actualiza actualizaciones.ps1 (spec 042); esto es lo nuestro.
#
#   scripts\actualizar-mediacenter.ps1 [-Version 2026.10.18.1]   a mano
#   scripts\actualizar-mediacenter.ps1 -Lanzar <CONFIG_ROOT>
#       lo usa qbt-abrir.cmd (tarea de cada minuto, cortada al minuto) si ve
#       el aviso del panel: (re)crea la tarea "MediaCenter actualizar
#       programa", sin limite de tiempo, y la lanza.
#   scripts\actualizar-mediacenter.ps1 -DesdePanel <CONFIG_ROOT>
#       lo que corre esa tarea: lee la version del aviso
#       (<CONFIG_ROOT>\disk-report\actualizar-mediacenter), actualiza y deja
#       el resultado en mediacenter-actualizacion.json para el panel.
#
# Nunca toca .env, docker-compose.override.yml, docker-config ni los datos.
# Si despues la comprobacion (spec 049) tiene fallos que antes no tenia,
# vuelve a los ficheros de antes (.anterior) y lo dice.
param([string]$Version, [string]$Lanzar, [string]$DesdePanel)

[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$TaskName = 'MediaCenter actualizar programa'
$Repo = 'DiegoSMR/MediaCenter-App-Download'
# Lo de este PC, que el paquete no trae y nunca se toca.
$Propio = @('.env', 'docker-compose.override.yml', 'instalacion.log', 'PRIMEROS-PASOS.html', 'reiniciar.flag')
$PropioDirs = @('docker-config', '.anterior', '.git')

if ($Lanzar) {
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

function Get-Epoch { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
function Paso([string]$m) { Write-Host "[$(Get-Date -Format HH:mm:ss)] $m"; if ($script:LogFile) { Add-Content -LiteralPath $script:LogFile -Value "[$(Get-Date -Format s)] $m" -Encoding UTF8 } }

$resultFile = $null; $running = $null
if ($DesdePanel) {
    $stateDir = Join-Path $DesdePanel 'disk-report'
    $resultFile = Join-Path $stateDir 'mediacenter-actualizacion.json'
    $flag = Join-Path $stateDir 'actualizar-mediacenter'
    if (-not (Test-Path -LiteralPath $flag)) { return }
    $running = "$flag.en-curso"
    Move-Item -LiteralPath $flag -Destination $running -Force
    $Version = (Get-Content -LiteralPath $running -Raw).Trim()
    $script:LogFile = Join-Path $stateDir 'mediacenter-actualizacion.log'
    Set-Content -LiteralPath $script:LogFile -Value '' -Encoding UTF8
}

function Read-VersionEnv([string]$dir) {
    $f = Join-Path $dir 'version.env'
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    $l = Get-Content -LiteralPath $f | Where-Object { $_ -match '^MC_VERSION=' } | Select-Object -First 1
    if ($l) { ($l -split '=', 2)[1].Trim() } else { $null }
}

function Read-Manifest([string]$dir) {
    $f = Join-Path $dir 'MANIFEST.txt'
    if (Test-Path -LiteralPath $f) { @(Get-Content -LiteralPath $f | Where-Object { $_ }) } else { @() }
}

# Comprobacion (spec 049): los FALLOS como "App|Comprobacion". $null si no se
# ha podido ni ejecutar.
function Get-Fallos {
    $out = docker compose --profile tools run --rm --no-deps --build --entrypoint python3 disk-clean -u /app/verify.py --json 2>$null
    $json = $out | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1
    try { $r = $json | ConvertFrom-Json } catch { return $null }
    if (-not $r) { return $null }
    , @($r.checks | Where-Object { $_.level -eq 'fallo' } | ForEach-Object { "$($_.app)|$($_.name)|$($_.detail)" })
}

# Relanza bootstrap (aplica la configuracion de la version nueva) y espera.
function Invoke-Bootstrap {
    docker compose up -d --no-deps --force-recreate bootstrap 2>$null | Out-Null
    for ($i = 0; $i -lt 120; $i++) {
        Start-Sleep -Seconds 5
        if ((docker inspect bootstrap --format '{{.State.Status}}' 2>$null) -eq 'exited') { break }
    }
}

function Copy-Paquete([string]$from, [string]$to, [string[]]$quitar) {
    # /E: copia encima; lo propio de este PC no viene en el paquete. Despues,
    # se borra lo que era de MediaCenter y ya no esta.
    robocopy $from $to /E /XD @PropioDirs /XF @Propio /NFL /NDL /NJH /NJS /NP | Out-Null
    foreach ($rel in $quitar) {
        $p = Join-Path $to ($rel -replace '/', '\')
        if (Test-Path -LiteralPath $p -PathType Leaf) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
    }
}

Push-Location $ProjectRoot
$last = @{ at = (Get-Epoch); ok = $false; from = (Read-VersionEnv $ProjectRoot); to = $Version; message = '' }
$tmp = Join-Path $env:TEMP "mediacenter-actualizacion"
try {
    if (Test-Path -LiteralPath (Join-Path $ProjectRoot '.git')) { throw 'Esto es una copia de git (desarrollo): se actualiza con git, no con el paquete.' }
    if (-not $Version) {
        $tags = Invoke-RestMethod -UseBasicParsing -Uri "https://api.github.com/repos/$Repo/tags?per_page=100" -Headers @{ 'User-Agent' = 'MediaCenter' }
        $Version = @($tags | ForEach-Object { $_.name -replace '^v', '' } | Sort-Object { [version]$_ } -Descending)[0]
        $last.to = $Version
    }
    if (-not $Version -or $Version -notmatch '^\d{4}\.\d{1,2}\.\d{1,2}\.\d+$') { throw "Version no valida: '$Version'" }
    Paso "Actualizando MediaCenter de $($last.from) a $Version..."

    # 1. Descargar y descomprimir la etiqueta (zip publico de GitHub)
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $zip = Join-Path $tmp 'paquete.zip'
    $ProgressPreference = 'SilentlyContinue'
    $ok = $false
    foreach ($i in 1..3) {
        try { Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/$Repo/archive/refs/tags/v$Version.zip" -OutFile $zip -UserAgent 'MediaCenter'; $ok = $true; break }
        catch { Paso "Descarga fallida ($($_.Exception.Message)), intento $i de 3"; Start-Sleep -Seconds 10 }
    }
    if (-not $ok) { throw 'No se ha podido descargar la version nueva (internet o GitHub).' }
    Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $tmp 'x') -Force
    $nuevo = @(Get-ChildItem -LiteralPath (Join-Path $tmp 'x') -Directory)[0].FullName
    if ((Read-VersionEnv $nuevo) -ne $Version -or -not (Test-Path -LiteralPath (Join-Path $nuevo 'docker-compose.yml'))) {
        throw 'El paquete descargado no es el esperado (version.env o docker-compose.yml). No se toca nada.'
    }
    $manNuevo = Read-Manifest $nuevo
    $manViejo = Read-Manifest $ProjectRoot

    # 2. Comprobacion antes: solo cuentan los fallos NUEVOS
    Paso 'Comprobando la instalacion antes de actualizar...'
    $antes = Get-Fallos
    if ($null -eq $antes) { $antes = @() }

    # 3. Copia de seguridad: configuracion (servicio backup) y programa (.anterior)
    Paso 'Copia de seguridad de la configuracion...'
    $since = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    docker compose restart backup 2>$null | Out-Null
    $backupOk = $false
    for ($i = 0; $i -lt 120; $i++) {
        if ((docker compose logs --since $since backup 2>$null | Out-String) -match 'Backup completado') { $backupOk = $true; break }
        Start-Sleep -Seconds 5
    }
    if (-not $backupOk) { throw 'La copia de seguridad no ha terminado: no se actualiza (mira "docker compose logs backup").' }
    $anterior = Join-Path $ProjectRoot '.anterior'
    robocopy $ProjectRoot $anterior /MIR /XD @PropioDirs /XF @Propio /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "No se ha podido copiar el programa actual a .anterior (robocopy $LASTEXITCODE)." }

    # 4. Sustituir los ficheros, reconstruir y aplicar la configuracion
    Paso 'Sustituyendo los ficheros de MediaCenter...'
    Copy-Paquete $nuevo $ProjectRoot @($manViejo | Where-Object { $_ -notin $manNuevo })
    Paso 'Reconstruyendo y arrancando...'
    $env:COMPOSE_PARALLEL_LIMIT = '3'
    docker compose up -d --build --remove-orphans 2>$null | Out-Null
    $upOk = $LASTEXITCODE -eq 0
    Invoke-Bootstrap

    # 5. Comprobacion despues; si hay fallos nuevos, volver atras
    Paso 'Comprobando la instalacion despues de actualizar...'
    $despues = Get-Fallos
    $nuevos = if ($null -eq $despues) { @('La comprobacion no se ha podido ejecutar') } else { @($despues | Where-Object { $_ -notin $antes }) }
    if (-not $upOk -or $nuevos.Count) {
        $por = if (-not $upOk) { 'no han arrancado las aplicaciones' } else { ($nuevos | ForEach-Object { ($_ -split '\|')[0..1] -join ': ' }) -join '; ' }
        Paso "Algo ha fallado ($por): volviendo a la version anterior..."
        Copy-Paquete $anterior $ProjectRoot @($manNuevo | Where-Object { $_ -notin $manViejo })
        docker compose up -d --build --remove-orphans 2>$null | Out-Null
        Invoke-Bootstrap
        $last.message = "No se ha actualizado a $Version : $por. Se ha vuelto a la version $($last.from)."
    } else {
        $last.ok = $true
        $last.message = "MediaCenter actualizado a $Version."
    }
} catch {
    $last.message = "No se ha actualizado: $($_.Exception.Message)"
} finally {
    Paso $last.message
    Pop-Location
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    if ($resultFile) {
        $out = @{ last_update = $last; version = (Read-VersionEnv $ProjectRoot) }
        [IO.File]::WriteAllText($resultFile, ($out | ConvertTo-Json -Compress -Depth 5), (New-Object Text.UTF8Encoding $false))
    }
    if ($running) { Remove-Item -LiteralPath $running -Force -ErrorAction SilentlyContinue }
}
