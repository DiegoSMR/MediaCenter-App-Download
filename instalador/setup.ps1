# =============================================================================
# setup.ps1 — el trabajo de verdad del instalador MediaCenter-Setup.exe
# (spec 039). Lo lanza Inno Setup (MediaCenter.iss); no hace falta usarlo a
# mano. Tres fases:
#
#   -Phase Install -Answers <fichero>   (con permisos de administrador)
#       comprobaciones, .env, carpetas, qBittorrent en Windows (perfil,
#       tareas programadas), override de Compose, firewall, suspension, y
#       Docker Desktop si falta. WSL NO se instala: si falta, se pausa y se
#       explica al usuario como instalarlo (Wait-Wsl). Si hace falta reiniciar, deja la
#       fase Start en una tarea al iniciar sesion y crea "reiniciar.flag"
#       para que Inno lo pida.
#       Si no, sigue con Start.
#   -Phase Start      (tras el reinicio, al iniciar sesion; o seguido)
#       Docker Desktop -> qBittorrent -> docker compose up -> recyclarr ->
#       firstrun (asistentes de Jellyfin/Seerr...) -> "Primeros pasos".
#   -Phase Uninstall  para y quita contenedores, tareas y reglas. NUNCA
#       borra peliculas/series ni la configuracion salvo -BorrarDatos.
#
#   -NoInstall   nunca instala Docker/qBittorrent: si falta, falla.
#                OBLIGATORIO en cualquier prueba en un PC ya preparado
#                (la spec 020 actualizo sin querer el Docker del usuario).
#
# Registro: <carpeta de instalacion>\instalacion.log
# Notas PowerShell 5.1 (el de todos los Windows): nada de
# ErrorActionPreference=Stop (convierte el stderr de docker en error) y el
# fichero va en UTF-8 CON BOM (sin el, 5.1 rompe las tildes).
# =============================================================================
param(
    [ValidateSet('Install', 'Start', 'Uninstall')][string]$Phase = 'Start',
    [string]$Answers,
    [switch]$NoInstall,
    [switch]$BorrarDatos,
    [switch]$NoOpen
)

$App = Split-Path -Parent $PSScriptRoot          # carpeta de instalacion (docker-compose.yml)
$Log = Join-Path $App 'instalacion.log'
$TaskQbt = 'MediaCenter qBittorrent'
$TaskPanel = 'MediaCenter qBittorrent (panel)'
$TaskResume = 'MediaCenter terminar instalacion'
$RunOnceName = 'MediaCenterInstalacion'   # version anterior: se limpia si quedo
$RestartFlag = Join-Path $App 'reiniciar.flag'
$FwPrefix = 'MediaCenter - '
# qBittorrent (sin winget, ver Invoke-Install): version fija con su huella (comprobada el
# 2026-09-30; su SHA-1 coincide con la que publica SourceForge).
$QbtVersion = '5.2.3'
$QbtUrl = "https://downloads.sourceforge.net/project/qbittorrent/qbittorrent-win32/qbittorrent-$QbtVersion/qbittorrent_${QbtVersion}_x64_setup.exe"
$QbtSha256 = 'FF508E2F912D59C9EABAF03633EBACFD45C2049F38DCAC027B8A7D7AD867AB2F'
Add-Type -AssemblyName System.Windows.Forms
$env:WSL_UTF8 = '1'   # wsl.exe escribe UTF-16 por defecto: en el registro salia "N o   s e   p u d o"

function Write-Paso([string]$msg) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $msg
    Write-Host $line
    Add-Content -LiteralPath $Log -Value $line -Encoding UTF8
}

function Show-Mensaje([string]$msg, [string]$icono = 'Information') {
    [void][Windows.Forms.MessageBox]::Show($msg, 'MediaCenter', 'OK', $icono)
}

function Stop-ConError([string]$msg) {
    Write-Paso "ERROR: $msg"
    Show-Mensaje "$msg`n`nMás detalles en:`n$Log" 'Error'
    exit 1
}

# Ejecuta un programa externo, manda su salida al registro y devuelve el
# codigo de salida (sin que PowerShell 5.1 trate el stderr como error).
function Invoke-Externo([string]$exe, [string]$argumentos) {
    Add-Content -LiteralPath $Log -Value "> $exe $argumentos" -Encoding UTF8
    $out = cmd /c "`"$exe`" $argumentos 2>&1"
    $code = $LASTEXITCODE
    # Sin las barras de progreso ("[====  83.5%  ]"): wsl --install escribe cientos.
    $out = $out | Where-Object { $_ -notmatch '^\s*\[[=\s]*\d+(\.\d+)?%[=\s]*\]\s*$' }
    if ($out) { Add-Content -LiteralPath $Log -Value $out -Encoding UTF8 }
    return $code
}

# Comprobacion de la instalacion (spec 049): disk-report/verify.py en la
# imagen de disk-clean (misma imagen y montajes que el panel). Devuelve los
# FALLOS como texto ("App: comprobacion -- detalle. Que hacer: ..."); los
# avisos solo van al log. Si no se puede ni ejecutar, eso es un fallo.
function Invoke-Comprobacion([string]$docker) {
    Add-Content -LiteralPath $Log -Value "> $docker compose run (verify.py)" -Encoding UTF8
    $out = cmd /c "`"$docker`" compose --profile tools run --rm --no-deps --build --entrypoint python3 disk-clean -u /app/verify.py --json 2>nul"
    $json = $out | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1
    try { $r = $json | ConvertFrom-Json } catch { $r = $null }
    if (-not $r) {
        Add-Content -LiteralPath $Log -Value $out -Encoding UTF8
        return @('No se ha podido ejecutar la comprobación (verify.py): mira el registro.')
    }
    $fallos = @()
    foreach ($c in $r.checks) {
        if ($c.level -eq 'ok') { continue }
        $t = "$($c.app): $($c.name)" + $(if ($c.detail) { " -- $($c.detail)" } else { '' })
        Add-Content -LiteralPath $Log -Value ("  [{0}] {1}" -f $c.level.ToUpper(), $t) -Encoding UTF8
        if ($c.level -eq 'fallo') { $fallos += $t + $(if ($c.fix) { " Qué hacer: $($c.fix)" } else { '' }) }
    }
    Add-Content -LiteralPath $Log -Value ("  Comprobación: {0} bien, {1} avisos, {2} fallos." -f $r.summary.ok, $r.summary.aviso, $r.summary.fallo) -Encoding UTF8
    return , $fallos
}

function Read-DotEnv {
    $h = @{}
    $f = Join-Path $App '.env'
    if (Test-Path -LiteralPath $f) {
        foreach ($l in Get-Content -LiteralPath $f -Encoding UTF8) {
            if ($l -match "^([A-Z_]+)=(.*)$") {
                $v = $Matches[2]
                if ($v.Length -ge 2 -and $v.StartsWith("'") -and $v.EndsWith("'")) { $v = $v.Substring(1, $v.Length - 2) }
                $h[$Matches[1]] = $v
            }
        }
    }
    return $h
}

function Get-LanIp {
    $c = Get-NetIPConfiguration -ErrorAction SilentlyContinue |
        Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } | Select-Object -First 1
    if ($c) { return $c.IPv4Address[0].IPAddress }
    return 'localhost'
}

function Get-ZonaHoraria {
    # PowerShell 5.1 no convierte ids de Windows a IANA: los habituales, y
    # Madrid por defecto (el publico es de Espana).
    $map = @{
        'Romance Standard Time' = 'Europe/Madrid'; 'Canary Standard Time' = 'Atlantic/Canary'
        'GMT Standard Time' = 'Europe/London'; 'W. Europe Standard Time' = 'Europe/Berlin'
        'Central Europe Standard Time' = 'Europe/Budapest'; 'SA Pacific Standard Time' = 'America/Bogota'
        'Central Standard Time (Mexico)' = 'America/Mexico_City'; 'Argentina Standard Time' = 'America/Argentina/Buenos_Aires'
    }
    $id = [TimeZoneInfo]::Local.Id
    if ($map.ContainsKey($id)) { return $map[$id] }
    return 'Europe/Madrid'
}

function Find-DockerDesktop {
    # Docker Desktop puede estar instalado para todos (Program Files) o por
    # usuario (AppData\Local\Programs): la spec 020 solo miraba el primero,
    # creyo que faltaba y lo reinstalo/actualizo en el PC del usuario.
    $cands = @(
        "$env:ProgramFiles\Docker\Docker",
        "$env:LOCALAPPDATA\Programs\DockerDesktop",
        "$env:LOCALAPPDATA\Programs\Docker\Docker"
    )
    foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Docker Desktop',
                   'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Docker Desktop') {
        $loc = (Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue).InstallLocation
        if ($loc) { $cands = @($loc) + $cands }
    }
    foreach ($d in $cands) {
        if ($d -and (Test-Path -LiteralPath (Join-Path $d 'Docker Desktop.exe'))) { return $d }
    }
    $cli = Get-Command docker -ErrorAction SilentlyContinue
    if ($cli) {
        # ...\Docker\Docker\resources\bin\docker.exe -> ...\Docker\Docker
        $d = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $cli.Source))
        if (Test-Path -LiteralPath (Join-Path $d 'Docker Desktop.exe')) { return $d }
    }
    return $null
}

# Como con Docker: si el usuario ya tiene qBittorrent, se usa ese y no se
# instala otra copia, este donde este instalado. Solo se usa el programa:
# MediaCenter arranca con su propio perfil (--profile), asi que la
# configuracion y los torrents que el usuario ya tuviera no se tocan.
function Find-QBittorrent {
    $cands = New-Object System.Collections.Generic.List[string]
    # El instalador oficial guarda la carpeta aqui (visto en este PC)
    foreach ($k in 'HKLM:\SOFTWARE\qBittorrent', 'HKLM:\SOFTWARE\WOW6432Node\qBittorrent', 'HKCU:\SOFTWARE\qBittorrent') {
        $loc = (Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue).InstallLocation
        if ($loc) { $cands.Add((Join-Path $loc 'qbittorrent.exe')) }
    }
    # Entrada de "Aplicaciones instaladas" (tambien las de winget/Chocolatey)
    foreach ($r in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                   'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
                   'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall') {
        $apps = Get-ChildItem -LiteralPath $r -ErrorAction SilentlyContinue | Get-ItemProperty -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like 'qBittorrent*' }
        foreach ($e in $apps) {
            if ($e.InstallLocation) { $cands.Add((Join-Path $e.InstallLocation 'qbittorrent.exe')) }
            # "C:\Program Files\qBittorrent\qbittorrent.exe",0
            if ($e.DisplayIcon) { $cands.Add(($e.DisplayIcon -replace ',\s*-?\d+$', '').Trim('"', ' ')) }
            if ($e.UninstallString) {
                $u = [regex]::Match($e.UninstallString, '^"?([^"]+\\)[^\\"]+\.exe').Groups[1].Value
                if ($u) { $cands.Add((Join-Path $u 'qbittorrent.exe')) }
            }
        }
    }
    foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\qbittorrent.exe',
                   'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\qbittorrent.exe') {
        $v = (Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue).'(default)'
        if ($v) { $cands.Add($v.Trim('"')) }
    }
    # Abierto ahora mismo, o en el PATH (portable, Scoop...)
    foreach ($pr in @(Get-Process qbittorrent -ErrorAction SilentlyContinue)) { if ($pr.Path) { $cands.Add($pr.Path) } }
    $cli = Get-Command qbittorrent.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cli) { $cands.Add($cli.Source) }
    foreach ($p in "$env:ProgramFiles\qBittorrent\qbittorrent.exe", "${env:ProgramFiles(x86)}\qBittorrent\qbittorrent.exe",
                   "$env:LOCALAPPDATA\Programs\qBittorrent\qbittorrent.exe", "$env:USERPROFILE\scoop\apps\qbittorrent\current\qbittorrent.exe") {
        $cands.Add($p)
    }
    foreach ($p in $cands) {
        if ($p -and (Test-Path -LiteralPath $p -PathType Leaf)) { return (Resolve-Path -LiteralPath $p).ProviderPath }
    }
    return $null
}

# Puertos del qBittorrent de MediaCenter: 8080 (web) y 6881 (torrents) si
# estan libres. Si no (otro programa, o el qBittorrent propio del usuario,
# abierto o cerrado), el siguiente libre. Van al .env (QBT_URL,
# QBT_LISTEN_PORT) y de ahi los leen bootstrap, disk-report y scripts\.
function Get-QbtIniPuertos([string]$ini) {
    $r = @{ Web = 0; Torrent = 0 }
    if (-not (Test-Path -LiteralPath $ini)) { return $r }
    foreach ($l in Get-Content -LiteralPath $ini -ErrorAction SilentlyContinue) {
        if ($l -match '^WebUI\\Port=(\d+)') { $r.Web = [int]$Matches[1] }
        # Session\Port en qBittorrent 4.4+, Connection\PortRangeMin antes
        elseif ($l -match '^(Session\\Port|Connection\\PortRangeMin)=(\d+)') { $r.Torrent = [int]$Matches[2] }
    }
    return $r
}

function Get-PuertosOcupados {
    $p = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($c in @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue)) { [void]$p.Add([int]$c.LocalPort) }
    foreach ($c in @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue)) { [void]$p.Add([int]$c.LocalPort) }
    # Rangos que reserva Windows (Hyper-V, WSL, Docker): nadie escucha en ellos, pero no se pueden usar
    foreach ($proto in 'tcp', 'udp') {
        foreach ($l in @(netsh int ipv4 show excludedportrange protocol=$proto 2>$null)) {
            if ($l -match '^\s*(\d+)\s+(\d+)') { foreach ($i in [int]$Matches[1]..[int]$Matches[2]) { [void]$p.Add($i) } }
        }
    }
    # Los del qBittorrent propio del usuario, aunque ahora este cerrado
    $inis = @("$env:APPDATA\qBittorrent\qBittorrent.ini")
    $q = Find-QBittorrent
    if ($q) { $inis += Join-Path (Split-Path -Parent $q) 'profile\qBittorrent\config\qBittorrent.ini' }   # portable
    foreach ($ini in $inis) {
        $u = Get-QbtIniPuertos $ini
        foreach ($n in $u.Web, $u.Torrent) { if ($n) { [void]$p.Add($n) } }
    }
    # Los que publica el propio stack (puede que Docker aun no este arrancado)
    foreach ($n in 1900, 3000, 3001, 5055, 6767, 7359, 7878, 8096, 8920, 8989, 9696) { [void]$p.Add($n) }
    return , $p
}

function Find-PuertoLibre([int]$preferido, $ocupados) {
    for ($i = $preferido; $i -lt $preferido + 500; $i++) {
        if (-not $ocupados.Contains($i)) { [void]$ocupados.Add($i); return $i }
    }
    Stop-ConError "No encuentro un puerto libre cerca del $preferido para qBittorrent."
}

# Puerto de la web de qBittorrent segun el .env (8080 si es antiguo)
function Get-QbtWebUrl($cfg) {
    if ($cfg['QBT_URL'] -match ':(\d+)/?$') { return "http://localhost:$($Matches[1])" }
    return 'http://localhost:8080'
}

# Enlaces magnet y .torrent al qBittorrent de MediaCenter (2026-10-18). El
# instalador de qBittorrent los registra como qbittorrent.exe "%1", SIN
# perfil: con el de MediaCenter abierto (--profile=...), un magnet abria
# OTRO qBittorrent con el perfil normal (solo hay una instancia por
# perfil). Con --profile, se lo pasa al que ya esta abierto. En HKCU (este
# usuario; se llama desde Start, que corre como el, no como administrador):
# pisa lo de HKLM y una actualizacion de qBittorrent no lo deshace.
$QbtProgIds = @('magnet', 'qBittorrent.Url.Magnet', 'qBittorrent.File.Torrent')
function Set-QbtAsociaciones([string]$exe, [string]$perfil) {
    if (-not $exe -or -not (Test-Path -LiteralPath $exe)) { return }
    $cmd = "`"$exe`" --profile=`"$perfil`" `"%1`""
    foreach ($c in $QbtProgIds) {
        $k = "HKCU:\Software\Classes\$c\shell\open\command"
        New-Item -Path $k -Force | Out-Null
        Set-ItemProperty -LiteralPath $k -Name '(default)' -Value $cmd
    }
    Set-ItemProperty -LiteralPath 'HKCU:\Software\Classes\magnet' -Name '(default)' -Value 'URL:Magnet URI'
    Set-ItemProperty -LiteralPath 'HKCU:\Software\Classes\magnet' -Name 'URL Protocol' -Value ''
    Write-Paso 'Enlaces magnet y .torrent: se abren en el qBittorrent de MediaCenter.'
}
function Remove-QbtAsociaciones {
    # Solo si son nuestras (llevan el perfil de MediaCenter): vuelve lo de HKLM.
    foreach ($c in $QbtProgIds) {
        $k = "HKCU:\Software\Classes\$c\shell\open\command"
        if ((Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue).'(default)' -match 'qbittorrent-nativo') {
            Remove-Item -LiteralPath "HKCU:\Software\Classes\$c" -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-Wsl {
    # Sin WSL, wsl.exe solo existe como "instalador" y --status falla.
    return (Invoke-Externo 'wsl.exe' '--status') -eq 0
}

# WSL NO se instala solo (visto en el PC de un usuario: "wsl --install"
# fallaba con Wsl/CallMsi/Install/REGDB_E_CLASSNOTREG, WSL a medio instalar,
# y los reintentos solo alargaban la espera). Es parte de Windows, a menudo
# pide reiniciar y, si falla, solo el usuario puede arreglarlo: se pausa la
# instalacion, se le explica por que y como, y se comprueba otra vez.
function Wait-Wsl {
    $cmd = 'wsl --install --no-distribution'
    while (-not (Test-Wsl)) {
        Write-Paso 'Falta WSL (Subsistema de Windows para Linux): instalación en pausa hasta que el usuario lo instale.'
        try { Set-Clipboard -Value $cmd } catch { }
        $msg = "Falta el «Subsistema de Windows para Linux» (WSL) y MediaCenter lo necesita.`n`n" +
            "POR QUÉ: MediaCenter funciona con Docker, y Docker usa WSL para ejecutar sus aplicaciones en Windows. " +
            "Es una pieza del propio Windows: instalarla automáticamente a veces falla y suele pedir reiniciar, " +
            "así que es mejor que la instales tú. Son unos 5 minutos.`n`n" +
            "CÓMO:`n" +
            "1. Pulsa con el botón derecho el botón Inicio de Windows y elige «Terminal (administrador)». Acepta el aviso.`n" +
            "2. Pega este comando con Ctrl+V (ya está copiado) y pulsa Intro:`n" +
            "        $cmd`n" +
            "3. Espera a que termine. Si pide reiniciar, reinicia el PC y vuelve a abrir este instalador " +
            "(lo que ya está hecho se conserva). Si no lo pide, pulsa «Reintentar».`n`n" +
            "¿Te sale un error en el paso 2? Entra en github.com/microsoft/WSL/releases, descarga el archivo " +
            "que termina en «x64.msi», ábrelo con doble clic, reinicia el PC y vuelve a abrir este instalador.`n`n" +
            "La instalación de MediaCenter queda en pausa mientras tanto."
        $r = [Windows.Forms.MessageBox]::Show($msg, 'MediaCenter - falta WSL', 'RetryCancel', 'Warning')
        if ($r -ne 'Retry') {
            Stop-ConError 'Instalación cancelada: falta WSL. Instálalo como se explicaba y vuelve a abrir el instalador.'
        }
    }
    Write-Paso 'WSL instalado.'
}

function Test-Virtualizacion {
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $cs = Get-CimInstance Win32_ComputerSystem
    # Con un hipervisor ya en marcha (WSL2, Hyper-V), Windows dice "False"
    # en VirtualizationFirmwareEnabled aunque este activada.
    return [bool]($cpu.VirtualizationFirmwareEnabled -or $cs.HypervisorPresent)
}

# Hash de contrasena de la WebUI de qBittorrent: PBKDF2-SHA512, 100000
# iteraciones, sal de 16 bytes, clave de 64 (el mismo formato que el hash
# fijo de bootstrap/qbt-seed.sh; comprobado que da el mismo resultado).
function New-QbtPasswordHash([string]$password) {
    $salt = New-Object byte[] 16
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($salt)
    $kdf = New-Object Security.Cryptography.Rfc2898DeriveBytes ([Text.Encoding]::UTF8.GetBytes($password)), $salt, 100000, ([Security.Cryptography.HashAlgorithmName]::SHA512)
    return '@ByteArray({0}:{1})' -f [Convert]::ToBase64String($salt), [Convert]::ToBase64String($kdf.GetBytes(64))
}

function Write-Utf8([string]$path, [string]$text) {
    [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding $false))
}

# Docker sin el almacen de credenciales de Windows para las ordenes del
# instalador (todas las imagenes son publicas). Desde algunos contextos
# (elevado, tareas) falla con "Una sesion de inicio especificada no existe" y
# no se podia ni descargar ni compilar (visto en la VM). Ni un config sin
# credsStore ni quitar los docker-credential-*.exe del PATH bastan: compose
# pull se empeña en "wincred". Solucion: un ayudante propio, "nada", que
# siempre dice "no hay credenciales" (descarga anonima). Probado en la VM con
# permisos normales y elevados, compose pull y compose build.
function Use-DockerSinCredenciales {
    $cfg = Join-Path $App 'docker-config'
    [void](New-Item -ItemType Directory -Force -Path $cfg)
    Write-Utf8 (Join-Path $cfg 'config.json') '{"auths":{},"credsStore":"nada"}'
    Write-Utf8 (Join-Path $cfg 'docker-credential-nada.cmd') ((@(
        '@echo off'
        'if "%1"=="get" (echo credentials not found in native keychain& exit /b 1)'
        'if "%1"=="list" (echo {}& exit /b 0)'
        'exit /b 0') -join "`r`n") + "`r`n")
    $env:DOCKER_CONFIG = $cfg
    $env:DOCKER_HOST = 'npipe:////./pipe/dockerDesktopLinuxEngine'
    $env:PATH = $cfg + ';' + ((($env:PATH -split ';') | Where-Object { $_ -and -not (Test-Path (Join-Path $_ 'docker-credential-*.exe')) }) -join ';')
}

# Docker Desktop recien instalado viene con "arrancar al iniciar sesion"
# DESACTIVADO (AutoStart false): tras el primer reinicio MediaCenter dejaba de
# funcionar (visto en la VM). Se activa, y se quita que abra su ventana en cada
# arranque. Mejor con Docker parado: lee este fichero al arrancar.
function Set-DockerAutoStart {
    $f = Join-Path $env:APPDATA 'Docker\settings-store.json'
    $s = $null
    if (Test-Path -LiteralPath $f) { try { $s = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json } catch { } }
    if (-not $s) { $s = New-Object PSObject; [void](New-Item -ItemType Directory -Force -Path (Split-Path $f)) }
    foreach ($k in @{ AutoStart = $true; OpenUIOnStartupDisabled = $true }.GetEnumerator()) {
        $s | Add-Member -NotePropertyName $k.Key -NotePropertyValue $k.Value -Force
    }
    Write-Utf8 $f ($s | ConvertTo-Json -Depth 10)
}

# ---------------------------------------------------------------------------
# Fase Install (administrador)
# ---------------------------------------------------------------------------
function Invoke-Install {
    Write-Paso "=== Instalación de MediaCenter en $App ==="
    Remove-Item -LiteralPath $RestartFlag -Force -ErrorAction SilentlyContinue

    # --- Respuestas del asistente (clave=valor, UTF-8). Se borran al leerlas.
    if (-not $Answers -or -not (Test-Path -LiteralPath $Answers)) { Stop-ConError 'Faltan las respuestas del instalador.' }
    $a = @{}
    foreach ($l in Get-Content -LiteralPath $Answers -Encoding UTF8) {
        $i = $l.IndexOf('=')
        if ($i -gt 0) { $a[$l.Substring(0, $i)] = $l.Substring($i + 1) }
    }
    Remove-Item -LiteralPath $Answers -Force -ErrorAction SilentlyContinue

    # --- Comprobaciones
    $build = [Environment]::OSVersion.Version.Build
    if ($build -lt 22000) { Stop-ConError 'MediaCenter necesita Windows 11. Este PC tiene Windows 10 o anterior.' }
    $ramGb = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    if ($ramGb -lt 8) { Stop-ConError "MediaCenter necesita al menos 8 GB de memoria RAM (este PC tiene $ramGb GB)." }
    if (-not (Test-Virtualizacion)) {
        Stop-ConError ("La virtualización está desactivada en la BIOS de este PC, y MediaCenter la necesita.`n`n" +
            "Cómo activarla: reinicia el PC y, al encender, pulsa repetidamente Supr, F2 o F10 (depende de la marca) " +
            "para entrar en la BIOS. Busca una opción llamada 'Intel Virtualization Technology', 'VT-x', 'SVM Mode' o " +
            "'AMD-V', ponla en 'Enabled', guarda (normalmente F10) y vuelve a abrir este instalador.")
    }
    Write-Paso "Windows build $build, $ramGb GB de RAM, virtualización activada."
    Wait-Wsl   # antes de tocar nada: si cancela, el PC queda como estaba

    # --- Carpetas y .env
    $base = $a['DATADIR'].TrimEnd('\')
    $dataRoot = "$base\data"; $configRoot = "$base\config"; $backupRoot = "$base\backup"
    foreach ($d in "$dataRoot\torrents\movies", "$dataRoot\torrents\tv", "$dataRoot\torrents\incomplete",
                   "$dataRoot\media\movies", "$dataRoot\media\tv", "$dataRoot\descargas", $configRoot, $backupRoot) {
        [void](New-Item -ItemType Directory -Force -Path $d)
    }
    $fwd = { param($p) $p -replace '\\', '/' }
    $ip = Get-LanIp

    # --- Puertos de qBittorrent. Si el perfil ya existe (reinstalacion), los
    # suyos: no se toca, y su qBittorrent puede estar abierto ocupandolos.
    $qbtProfile = "$configRoot\qbittorrent-nativo"
    $ini = "$qbtProfile\qBittorrent\config\qBittorrent.ini"
    $ya = Get-QbtIniPuertos $ini
    if ($ya.Web -and $ya.Torrent) {
        $webPort = $ya.Web; $torPort = $ya.Torrent
    } else {
        $ocup = Get-PuertosOcupados
        $webPort = Find-PuertoLibre 8080 $ocup
        $torPort = Find-PuertoLibre 6881 $ocup
    }
    if ($webPort -ne 8080 -or $torPort -ne 6881) {
        Write-Paso "Los puertos habituales de qBittorrent están ocupados en este PC: se usan $webPort (web) y $torPort (torrents)."
    }

    # Idioma de los menus (pantalla del instalador, 2026-10-16): ingles por
    # defecto. Titulos y carteles van siempre en ingles (firstrun).
    $uiLang = if ($a['LANG'] -eq 'es') { 'es' } else { 'en' }
    $lines = @(
        '# Generado por el instalador de MediaCenter (spec 039). Ver README.md.',
        "DATA_ROOT='$(& $fwd $dataRoot)'", "CONFIG_ROOT='$(& $fwd $configRoot)'", "BACKUP_ROOT='$(& $fwd $backupRoot)'",
        'PUID=1000', 'PGID=1000', "TZ='$(Get-ZonaHoraria)'", "HOST_LAN_IP='$ip'",
        '# qBittorrent en Windows (no en Docker): ver docker-compose.override.yml.',
        "QBT_URL='http://host.docker.internal:$webPort'", "QBT_LISTEN_PORT='$torPort'", "QBT_DATA_DIR='$(& $fwd $dataRoot)'",
        "QBT_USER='$($a['USER'])'", "QBT_PASS='$($a['PASS'])'",
        '# Usuario del instalador: Jellyfin y Seerr (los configura el servicio firstrun).',
        "MC_USER='$($a['USER'])'", "MC_PASSWORD='$($a['PASS'])'",
        '# Radarr/Sonarr/Prowlarr: 1 = piden ese mismo usuario; 0 = sin login.',
        "ARR_LOGIN='$(if ($a['ARRLOGIN'] -eq '1') { '1' } else { '0' })'",
        '# Idioma de los menus de las apps (lo aplica firstrun una vez): en o es.',
        "UI_LANG='$uiLang'"
    )
    # GPU NVIDIA: el override se la da a Jellyfin y bootstrap/firstrun
    # activan la aceleracion (si no, Jellyfin la tenia en "none" y convertia
    # con el procesador aunque viera la GPU, 2026-10-16).
    $nvidia = [bool](Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match 'NVIDIA' })
    if ($nvidia) { $lines += '# Jellyfin convierte video con la GPU NVIDIA.', "JELLYFIN_HWACCEL='nvenc'" }
    if ($a['OSUSER']) { $lines += "OPENSUBTITLES_USER='$($a['OSUSER'])'", "OPENSUBTITLES_PASSWORD='$($a['OSPASS'])'" }
    Write-Utf8 (Join-Path $App '.env') (($lines -join "`r`n") + "`r`n")
    Write-Paso "Configuración escrita (.env). Datos en $base, IP $ip."

    # --- qBittorrent en Windows (spec 013: en Docker iba muchisimo mas lento)
    $qbt = Find-QBittorrent
    if ($qbt) {
        $qv = (Get-Item -LiteralPath $qbt).VersionInfo.ProductVersion
        Write-Paso "qBittorrent ya estaba instalado ($qv): se usa ese, no se instala otra copia."
        # El panel para/reanuda con torrents/stop|start, que es de qBittorrent 5
        if ($qv -match '^v?(\d+)\.' -and [int]$Matches[1] -lt 5) {
            Write-Paso "AVISO: qBittorrent $qv es antiguo; los botones de parar/reanudar descargas del panel necesitan la versión 5 o posterior."
        }
    } else {
        if ($NoInstall) { Stop-ConError 'Falta qBittorrent y se ha usado -NoInstall.' }
        # NO winget (visto en la VM de prueba): en un Windows recien estrenado
        # o no existe aun, o falla (-1978335138), o se queda colgado sin fin
        # mientras Windows instala actualizaciones. Siempre el instalador
        # oficial de una version fija, comprobando su huella antes de
        # ejecutarlo (su SHA-1 coincide con la que publica SourceForge).
        # qBittorrent avisa el mismo de versiones nuevas.
        # Va dentro del instalador (build.ps1): SourceForge fallo en la VM de
        # prueba (522). Descargarlo queda solo de respaldo, con reintentos.
        $inst = Join-Path $env:TEMP "qbittorrent_${QbtVersion}_x64_setup.exe"
        $incluido = Join-Path $PSScriptRoot "qbittorrent_${QbtVersion}_x64_setup.exe"
        if (Test-Path -LiteralPath $incluido) {
            Copy-Item -LiteralPath $incluido -Destination $inst -Force
        } else {
            Write-Paso "Descargando qBittorrent $QbtVersion de su web oficial..."
            $ProgressPreference = 'SilentlyContinue'
            $err = ''
            foreach ($i in 1..5) {
                # UserAgent: a PowerShell (que se presenta como navegador) SourceForge
                # le da una pagina "tu descarga empezara en breve" y no el .exe (visto
                # en la VM: la huella lo detecto y no se ejecuto nada).
                try { Invoke-WebRequest -UseBasicParsing -Uri $QbtUrl -OutFile $inst -UserAgent 'Wget/1.21.4'; $err = ''; break }
                catch { $err = $_.Exception.Message; Write-Paso "Descarga fallida ($err), intento $i de 5..."; Start-Sleep -Seconds 15 }
            }
            if ($err) { Stop-ConError "No se ha podido descargar qBittorrent: $err" }
        }
        $hash = (Get-FileHash -LiteralPath $inst -Algorithm SHA256).Hash
        if ($hash -ne $QbtSha256) {
            Remove-Item -LiteralPath $inst -Force -ErrorAction SilentlyContinue
            Stop-ConError "El instalador de qBittorrent descargado no es el esperado (huella $hash). No se ejecuta."
        }
        Write-Paso 'Instalando qBittorrent...'
        $p = Start-Process -FilePath $inst -ArgumentList '/S' -Wait -PassThru
        Remove-Item -LiteralPath $inst -Force -ErrorAction SilentlyContinue
        $qbt = Find-QBittorrent
        if (-not $qbt) { Stop-ConError "No se ha podido instalar qBittorrent (código del instalador: $($p.ExitCode))." }
    }
    Write-Paso "qBittorrent: $qbt"
    if (-not (Test-Path -LiteralPath $ini)) {
        [void](New-Item -ItemType Directory -Force -Path (Split-Path $ini))
        $dr = & $fwd $dataRoot
        Write-Utf8 $ini (@(
            '[LegalNotice]', 'Accepted=true', '',
            '[BitTorrent]',
            "Session\DefaultSavePath=$dr/descargas", "Session\TempPath=$dr/torrents/incomplete", 'Session\TempPathEnabled=true',
            "Session\Port=$torPort", 'Session\QueueingSystemEnabled=true', 'Session\MaxActiveDownloads=10',
            'Session\MaxActiveUploads=10', 'Session\MaxActiveTorrents=20', 'Session\IgnoreSlowTorrentsForQueueing=true',
            'Session\SlowTorrentsDownloadRate=10', 'Session\SlowTorrentsUploadRate=5',
            'Session\GlobalUPSpeedLimit=2048', 'Session\GlobalMaxSeedingMinutes=4320', '',
            '[Preferences]', "General\Locale=$uiLang", 'General\SystrayEnabled=true', 'General\MinimizeToTray=true',
            'General\CloseToTray=true', 'General\MinimizeToTrayNotified=true', 'General\ExitConfirm=false',
            'WebUI\Enabled=true', "WebUI\Port=$webPort", "WebUI\Username=$($a['USER'])",
            "WebUI\Password_PBKDF2=`"$(New-QbtPasswordHash $a['PASS'])`"", '',
            '[GUI]', 'StartUpWindowState=Hidden', ''
        ) -join "`r`n")
        Write-Paso "Perfil de qBittorrent creado (oculto en la bandeja, WebUI en el puerto $webPort, torrents en el $torPort)."
    } else {
        Write-Paso 'El perfil de qBittorrent ya existía: no se toca.'
    }

    # --- Override de Compose: qBittorrent fuera de Docker, y GPU NVIDIA si hay
    $ov = @('# Generado por el instalador (spec 039): solo para este PC.',
            '# qBittorrent corre en Windows, no en Docker (mucho mas rapido).',
            'services:', '  qbittorrent:', '    profiles: ["qbt-docker"]', '  qbt-seed:', '    profiles: ["qbt-docker"]')
    if ($nvidia) {
        $ov += '  # GPU NVIDIA detectada: Jellyfin la usa para convertir video (NVENC).',
               '  jellyfin:', '    environment:', '      NVIDIA_VISIBLE_DEVICES: all', '      NVIDIA_DRIVER_CAPABILITIES: all',
               '    deploy:', '      resources:', '        reservations:', '          devices:',
               '            - driver: nvidia', '              count: 1', '              capabilities: [gpu]'
    }
    Write-Utf8 (Join-Path $App 'docker-compose.override.yml') (($ov -join "`r`n") + "`r`n")
    Write-Paso "Override de Compose escrito (GPU NVIDIA: $nvidia)."

    # --- Tareas programadas (como en el PC del usuario, specs 013 y 030)
    $who = "$env:USERDOMAIN\$env:USERNAME"
    $principal = New-ScheduledTaskPrincipal -UserId $who -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $TaskQbt -Force -Principal $principal -Settings $settings `
        -Trigger (New-ScheduledTaskTrigger -AtLogOn -User $who) `
        -Action (New-ScheduledTaskAction -Execute $qbt -Argument "--profile=`"$qbtProfile`"") | Out-Null
    $cmd = Join-Path $App 'scripts\qbt-abrir.cmd'
    $settings2 = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $TaskPanel -Force -Principal $principal -Settings $settings2 `
        -Trigger (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)) `
        -Action (New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\conhost.exe" `
                 -Argument "--headless `"$env:SystemRoot\System32\cmd.exe`" /c `"`"$cmd`" `"$configRoot`"`"") | Out-Null
    Write-Paso "Tareas programadas creadas para $who."

    # --- Suspension (casilla del asistente, marcada por defecto)
    if ($a['NOSLEEP'] -eq '1') {
        [void](Invoke-Externo 'powercfg.exe' '/change standby-timeout-ac 0')
        [void](Invoke-Externo 'powercfg.exe' '/change hibernate-timeout-ac 0')
        Write-Paso 'Suspensión desactivada con el PC enchufado.'
    }

    # --- Docker Desktop (WSL ya comprobado al principio: Wait-Wsl)
    $reiniciar = $false
    $dd = Find-DockerDesktop
    if (-not $dd) {
        if ($NoInstall) { Stop-ConError 'Falta Docker Desktop y se ha usado -NoInstall.' }
        Write-Paso 'Descargando Docker Desktop (unos 600 MB, puede tardar)...'
        $inst = Join-Path $env:TEMP 'DockerDesktopInstaller.exe'
        $ProgressPreference = 'SilentlyContinue'
        $err = ''
        foreach ($i in 1..3) {
            try { Invoke-WebRequest -UseBasicParsing -Uri 'https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe' -OutFile $inst; $err = ''; break }
            catch { $err = $_.Exception.Message; Write-Paso "Descarga fallida ($err), intento $i de 3..."; Start-Sleep -Seconds 20 }
        }
        if ($err) { Stop-ConError "No se ha podido descargar Docker Desktop: $err" }
        Write-Paso 'Instalando Docker Desktop...'
        $p = Start-Process -FilePath $inst -ArgumentList 'install', '--quiet', '--accept-license', '--backend=wsl-2' -Wait -PassThru
        Remove-Item -LiteralPath $inst -Force -ErrorAction SilentlyContinue
        $dd = Find-DockerDesktop
        if (-not $dd) { Stop-ConError "No se ha podido instalar Docker Desktop (código $($p.ExitCode))." }
        $reiniciar = $true
    }
    Write-Paso "Docker Desktop: $dd"

    # --- Firewall: sin el aviso "¿Permitir acceso?" (programas que escuchan
    # en la red de casa: qBittorrent y el backend de Docker Desktop).
    Get-NetFirewallRule -DisplayName "$FwPrefix*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    $progs = @{ 'qBittorrent' = $qbt; 'Docker' = (Join-Path $dd 'resources\com.docker.backend.exe') }
    foreach ($n in $progs.Keys) {
        if (Test-Path -LiteralPath $progs[$n]) {
            foreach ($proto in 'TCP', 'UDP') {
                New-NetFirewallRule -DisplayName "$FwPrefix$n ($proto)" -Direction Inbound -Action Allow -Program $progs[$n] `
                    -Protocol $proto -Profile Private, Public | Out-Null
            }
        }
    }
    Write-Paso 'Reglas del firewall creadas.'

    if ($reiniciar) {
        # Reanudar tras el reinicio con una TAREA al iniciar sesion, no con
        # RunOnce: en la VM de prueba Windows borro la entrada de RunOnce sin
        # ejecutarla. La tarea (como la de qBittorrent, que si arranco) abre la
        # ventana de progreso y solo se borra cuando Start termina bien; si
        # falla, se reintenta en el siguiente inicio de sesion.
        # Con permisos NORMALES: con privilegios altos Docker no puede leer las
        # credenciales de Windows y falla hasta descargar una imagen publica
        # ("Una sesion de inicio especificada no existe", visto en la VM). Para
        # que aun asi pueda borrarse al terminar (la creo un administrador), su
        # descriptor de seguridad da control total al usuario; si no, Start se
        # repetia en cada inicio de sesion.
        $ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        Register-ScheduledTask -TaskName $TaskResume -Force -Principal $principal `
            -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)) `
            -Trigger (New-ScheduledTaskTrigger -AtLogOn -User $who) `
            -Action (New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Phase Start") | Out-Null
        $sid = (New-Object Security.Principal.NTAccount $who).Translate([Security.Principal.SecurityIdentifier]).Value
        $svc = New-Object -ComObject Schedule.Service
        $svc.Connect()
        $tarea = $svc.GetFolder('\').GetTask($TaskResume)
        $tarea.SetSecurityDescriptor($tarea.GetSecurityDescriptor(4) + "(A;;FA;;;$sid)", 0)   # 4 = DACL
        New-Item -ItemType File -Force -Path $RestartFlag | Out-Null
        Write-Paso 'Hace falta reiniciar. Al volver a iniciar sesión, la instalación continúa sola.'
        return
    }
    Invoke-Start
}

# ---------------------------------------------------------------------------
# Fase Start (usuario normal; tambien seguida de Install si no hubo reinicio)
# ---------------------------------------------------------------------------
function Invoke-Start {
    # Una sola a la vez (la tarea de inicio de sesion y el instalador a mano).
    $script:mutex = New-Object Threading.Mutex($false, 'Global\MediaCenterInstalacion')
    if (-not $script:mutex.WaitOne(0)) { Write-Paso 'Ya hay otra instalación en marcha; esta se cierra.'; return }
    $Host.UI.RawUI.WindowTitle = 'MediaCenter - terminando la instalación (no cierres esta ventana)'
    Write-Paso '=== Terminando la instalación de MediaCenter ==='
    Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name $RunOnceName -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $RestartFlag -Force -ErrorAction SilentlyContinue
    $cfg = Read-DotEnv
    if (-not $cfg['CONFIG_ROOT']) { Stop-ConError 'No encuentro la configuración (.env). Vuelve a ejecutar el instalador.' }

    # --- Docker Desktop en marcha
    $dd = Find-DockerDesktop
    if (-not $dd) { Stop-ConError 'No encuentro Docker Desktop. Vuelve a ejecutar el instalador.' }
    # Sin WSL Docker no arranca nunca: mejor decirlo que esperar 15 minutos.
    Wait-Wsl
    $docker = Join-Path $dd 'resources\bin\docker.exe'
    if (-not (Test-Path -LiteralPath $docker)) { $docker = 'docker.exe' }
    Set-DockerAutoStart
    Write-Paso 'Docker Desktop arrancará solo al iniciar sesión.'
    Use-DockerSinCredenciales
    if ((Invoke-Externo $docker 'info') -ne 0) {
        Write-Paso 'Arrancando Docker Desktop (la primera vez tarda unos minutos)...'
        Start-Process -FilePath (Join-Path $dd 'Docker Desktop.exe')
        $limite = (Get-Date).AddMinutes(15)
        while ((Invoke-Externo $docker 'info') -ne 0) {
            if ((Get-Date) -gt $limite) {
                Stop-ConError ('Docker Desktop no ha arrancado en 15 minutos. Ábrelo desde el menú Inicio, espera a que ' +
                    "diga 'Engine running' y vuelve a ejecutar el instalador.")
            }
            Start-Sleep -Seconds 10
        }
    }
    Write-Paso 'Docker Desktop funcionando.'

    # --- qBittorrent (bootstrap lo espera antes de configurar Radarr/Sonarr)
    Start-ScheduledTask -TaskName $TaskQbt -ErrorAction SilentlyContinue
    $limite = (Get-Date).AddMinutes(2)
    while ($true) {
        try { Invoke-WebRequest -UseBasicParsing -Uri "$(Get-QbtWebUrl $cfg)/api/v2/app/version" -TimeoutSec 5 | Out-Null; break }
        catch { if ($_.Exception.Response) { break } }   # cualquier respuesta HTTP (403) = abierto
        if ((Get-Date) -gt $limite) { Stop-ConError 'qBittorrent no ha arrancado.' }
        Start-Sleep -Seconds 3
    }
    Write-Paso 'qBittorrent funcionando.'
    Set-QbtAsociaciones (Find-QBittorrent) (Join-Path ($cfg['CONFIG_ROOT'] -replace '/', '\') 'qbittorrent-nativo')

    # --- El stack
    Push-Location $App
    try {
        # 1) Descargar las imagenes aparte, de 3 en 3 y con reintentos cada vez
        # mas espaciados: bajandolas todas a la vez, el registro de linuxserver
        # respondio "toomanyrequests" y luego hubo un "DeadlineExceeded" (VM).
        Write-Paso 'Descargando las aplicaciones (la primera vez, 10-30 minutos según tu conexión)...'
        $env:COMPOSE_PARALLEL_LIMIT = '3'
        $ok = $false
        $espera = 30
        foreach ($intento in 1..6) {
            if ((Invoke-Externo $docker 'compose pull --ignore-buildable') -eq 0) { $ok = $true; break }
            Write-Paso "La descarga se ha cortado (intento $intento de 6); reintentando en $espera s..."
            Start-Sleep -Seconds $espera
            $espera = [math]::Min($espera * 2, 300)
        }
        if (-not $ok) { Stop-ConError 'No se han podido descargar las aplicaciones. Comprueba la conexión a internet y vuelve a ejecutar el instalador.' }
        # 2) Arrancar. Reintentos: en un PC lento, la primera vez alguna app
        # tarda en estar "sana" y compose up aborta aunque luego arranque (VM).
        Write-Paso 'Arrancando las aplicaciones...'
        $ok = $false
        foreach ($intento in 1..4) {
            if ((Invoke-Externo $docker 'compose up -d --build') -eq 0) { $ok = $true; break }
            Write-Paso "Alguna aplicación aún no estaba lista (intento $intento de 4); reintentando en 60 s..."
            Start-Sleep -Seconds 60
        }
        if (-not $ok) { Stop-ConError 'No se han podido arrancar las aplicaciones (docker compose up).' }
        $bs = cmd /c "`"$docker`" inspect bootstrap --format {{.State.ExitCode}} 2>nul"
        if ("$bs".Trim() -ne '0') { Stop-ConError "La configuración automática (bootstrap) ha fallado (código $bs)." }
        Write-Paso 'Aplicaciones conectadas entre sí (bootstrap).'

        # Aplica los limites de tamano (70 MB/min en 1080p...): sin esto se
        # descargarian archivos enormes sin que nadie lo note. Descarga de
        # GitHub las guias de TRaSH, asi que un corte de internet la tumba.
        Write-Paso 'Perfiles de calidad y límites de tamaño (Recyclarr)...'
        $ok = $false
        foreach ($intento in 1..3) {
            if ((Invoke-Externo $docker 'compose run --rm --no-deps recyclarr sync') -eq 0) { $ok = $true; break }
            Write-Paso "Recyclarr no ha terminado bien (intento $intento de 3); reintentando en 30 s..."
            Start-Sleep -Seconds 30
        }
        if (-not $ok) {
            Stop-ConError ('No se han podido aplicar los perfiles de calidad y los límites de tamaño (Recyclarr). ' +
                'Suele ser la conexión a internet: compruébala y vuelve a abrir el instalador; lo ya hecho se conserva.')
        }

        Write-Paso 'Configurando Jellyfin, Seerr, The Pirate Bay y subtítulos (firstrun)...'
        $ok = $false
        foreach ($intento in 1..3) {
            if ((Invoke-Externo $docker 'compose --profile firstrun run --rm --build firstrun') -eq 0) { $ok = $true; break }
            Write-Paso "firstrun no ha terminado bien (intento $intento de 3); reintentando en 30 s..."
            Start-Sleep -Seconds 30
        }
        if (-not $ok) { Stop-ConError 'No se ha podido terminar de configurar Jellyfin/Seerr (firstrun).' }

        # Comprobacion final (spec 049): mira el RESULTADO en cada app. El
        # 2026-10-16 una instalacion acabo "bien" con Bazarr sin perfiles,
        # Jellyfin rechazando la clave y Radarr pidiendo login: cada ajuste
        # habia dado 200 sin aplicarse. Si algo falla, se vuelve a aplicar la
        # configuracion (bootstrap) una vez; si sigue, se explica y se sigue
        # (lo instalado funciona en parte, y el panel lo vuelve a mirar cada dia).
        Write-Paso 'Comprobando que todo ha quedado bien configurado...'
        $fallos = Invoke-Comprobacion $docker
        if ($fallos.Count) {
            Write-Paso "Algo no ha quedado bien ($($fallos.Count)): se vuelve a aplicar la configuración automática..."
            [void](Invoke-Externo $docker 'compose up -d --no-deps --force-recreate bootstrap')
            $limite = (Get-Date).AddMinutes(10)
            while ((Get-Date) -lt $limite) {
                Start-Sleep -Seconds 10
                $st = cmd /c "`"$docker`" inspect bootstrap --format {{.State.Status}} 2>nul"
                if ("$st".Trim() -eq 'exited') { break }
            }
            $fallos = Invoke-Comprobacion $docker
        }
        if ($fallos.Count) {
            Write-Paso "La comprobación final ha encontrado $($fallos.Count) problema(s):"
            $fallos | ForEach-Object { Write-Paso "  $_" }
            [void][Windows.Forms.MessageBox]::Show(
                ("MediaCenter está instalado, pero la comprobación final ha encontrado esto:`n`n" +
                 (($fallos | Select-Object -First 8) -join "`n`n") +
                 "`n`nLo verás también en el panel (Disco), que lo vuelve a comprobar cada día. " +
                 "El registro completo está en $Log."),
                'MediaCenter - comprobación final', 'OK', 'Warning')
        } else {
            Write-Paso 'Comprobación final: todo bien.'
        }
    } finally {
        Pop-Location
    }

    # --- Primeros pasos + accesos directos
    $ip = $cfg['HOST_LAN_IP']
    $tpl = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'primeros-pasos.html') -Raw -Encoding UTF8
    $qr = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'qrcode.js') -Raw -Encoding UTF8
    $torPort = if ($cfg['QBT_LISTEN_PORT']) { $cfg['QBT_LISTEN_PORT'] } else { '6881' }
    $html = $tpl.Replace('{{IP}}', $ip).Replace('{{PUERTO_TORRENT}}', $torPort).Replace('{{USUARIO}}', [Net.WebUtility]::HtmlEncode($cfg['MC_USER'])).Replace('{{LOG}}', $Log).Replace('/*{{QRCODE_JS}}*/', $qr)
    $pagina = Join-Path $App 'PRIMEROS-PASOS.html'
    Write-Utf8 $pagina $html
    $sh = New-Object -ComObject WScript.Shell
    $desk = [Environment]::GetFolderPath('Desktop')
    foreach ($s in @(@('MediaCenter.url', "http://$ip`:3000"), @('MediaCenter - Primeros pasos.lnk', $pagina))) {
        $f = Join-Path $desk $s[0]
        if ($s[0].EndsWith('.url')) { Write-Utf8 $f "[InternetShortcut]`r`nURL=$($s[1])`r`n" }
        else { $l = $sh.CreateShortcut($f); $l.TargetPath = $s[1]; $l.Save() }
    }
    # Terminado bien: ya no hace falta reanudar en el siguiente inicio de sesion.
    Unregister-ScheduledTask -TaskName $TaskResume -Confirm:$false -ErrorAction SilentlyContinue
    Write-Paso "Listo. Panel: http://$ip`:3000"
    if (-not $NoOpen) { Start-Process $pagina }
}

# ---------------------------------------------------------------------------
# Fase Uninstall
# ---------------------------------------------------------------------------
function Invoke-Uninstall {
    Write-Paso '=== Desinstalando MediaCenter ==='
    $cfg = Read-DotEnv
    Push-Location $App
    try {
        $dd = Find-DockerDesktop
        $docker = if ($dd -and (Test-Path -LiteralPath (Join-Path $dd 'resources\bin\docker.exe'))) { Join-Path $dd 'resources\bin\docker.exe' } else { 'docker.exe' }
        Use-DockerSinCredenciales
        [void](Invoke-Externo $docker 'compose --profile firstrun --profile tools down --remove-orphans')
    } finally { Pop-Location }
    try {
        $s = New-Object Microsoft.PowerShell.Commands.WebRequestSession
        Invoke-WebRequest -UseBasicParsing -Uri "$(Get-QbtWebUrl $cfg)/api/v2/app/shutdown" -Method Post -WebSession $s -TimeoutSec 5 | Out-Null
    } catch { }
    # Solo el de MediaCenter (su perfil): el qBittorrent propio del usuario sigue abierto
    Get-CimInstance Win32_Process -Filter "Name='qbittorrent.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'qbittorrent-nativo' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    foreach ($t in $TaskQbt, $TaskPanel, $TaskResume) { Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue }
    Remove-QbtAsociaciones
    Get-NetFirewallRule -DisplayName "$FwPrefix*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name $RunOnceName -ErrorAction SilentlyContinue
    $desk = [Environment]::GetFolderPath('Desktop')
    Remove-Item -LiteralPath (Join-Path $desk 'MediaCenter.url'), (Join-Path $desk 'MediaCenter - Primeros pasos.lnk') -Force -ErrorAction SilentlyContinue
    if ($BorrarDatos -and $cfg['DATA_ROOT']) {
        $base = Split-Path -Parent ($cfg['DATA_ROOT'] -replace '/', '\')
        Write-Paso "Borrando películas, series y configuración en $base (pedido por el usuario)..."
        foreach ($d in 'data', 'config', 'backup') { Remove-Item -LiteralPath (Join-Path $base $d) -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Write-Paso 'Desinstalado. Docker Desktop y qBittorrent siguen instalados (se quitan desde Configuración > Aplicaciones).'
}

switch ($Phase) {
    'Install' { Invoke-Install }
    'Start' { Invoke-Start }
    'Uninstall' { Invoke-Uninstall }
}
exit 0
