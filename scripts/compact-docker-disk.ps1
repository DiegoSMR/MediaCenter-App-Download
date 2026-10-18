<#
.SYNOPSIS
Compacta el disco virtual de WSL2 que respalda Docker Desktop
(docker_data.vhdx), que solo crece y nunca se encoge solo.

.DESCRIPTION
Para el stack, apaga WSL2 del todo (unos minutos de caida del stack,
inevitable: el .vhdx no se puede compactar mientras esta en uso),
compacta con diskpart (no requiere el modulo Hyper-V), reinicia Docker
Desktop, y vuelve a levantar el stack. Necesita ejecutarse como
Administrador -- diskpart lo exige; si no detecta privilegios de admin,
se relanza solo pidiendo elevacion.

Motivado por un caso real: docker_data.vhdx llego a pesar 94GB en una
maquina donde "docker system df" solo contaba ~6GB de uso real -- ver
development/history/024-instalador-espacio-disco.md y
development/history/008-resiliencia-docker-wsl2.md (entrada 2026-08-23).

.EXAMPLE
scripts\compact-docker-disk.ps1
#>

# --- 0. Autoelevacion si hace falta -----------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Este script necesita privilegios de administrador (diskpart lo exige). Relanzando con elevacion..."
    Start-Process powershell -Verb RunAs -ArgumentList "-NoExit", "-File", "`"$PSCommandPath`""
    exit
}

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$vhdxPath = "$env:LOCALAPPDATA\Docker\wsl\disk\docker_data.vhdx"

if (-not (Test-Path $vhdxPath)) {
    Write-Host "No se encontro $vhdxPath -- ¿ruta distinta en tu instalacion de Docker Desktop? Cancelando."
    exit 1
}

$before = (Get-Item $vhdxPath).Length / 1GB
Write-Host "Tamano actual de docker_data.vhdx: $([math]::Round($before, 2)) GB"

# --- 1. Parar el stack limpiamente (mejor que dejar que wsl --shutdown ------
#        corte en seco bases de datos SQLite de Radarr/Sonarr/etc.) ----------
Write-Host ""
Write-Host "-- Parando el stack (docker compose stop) --"
Push-Location $ProjectRoot
docker compose stop
Pop-Location

# --- 2. Apagar WSL2 del todo (obligatorio: el .vhdx no se puede tocar -------
#        mientras esta en uso) -----------------------------------------------
Write-Host ""
Write-Host "-- Apagando WSL2 (wsl --shutdown) --"
wsl --shutdown
Start-Sleep -Seconds 3

# --- 3. Compactar con diskpart (sin necesitar el modulo Hyper-V) ------------
Write-Host ""
Write-Host "-- Compactando el disco virtual (esto puede tardar varios minutos) --"
$diskpartScript = New-TemporaryFile
@"
select vdisk file="$vhdxPath"
attach vdisk readonly
compact vdisk
detach vdisk
exit
"@ | Set-Content -Path $diskpartScript -Encoding ASCII
diskpart /s $diskpartScript.FullName
Remove-Item $diskpartScript -Force

$after = (Get-Item $vhdxPath).Length / 1GB
Write-Host ""
Write-Host "Tamano tras compactar: $([math]::Round($after, 2)) GB (antes: $([math]::Round($before, 2)) GB, recuperado: $([math]::Round($before - $after, 2)) GB)"

# --- 4. Reiniciar Docker Desktop -- "wsl --shutdown" a veces deja el --------
#        backend de Docker Desktop colgado (visto en vivo: el WSL distro
#        "docker-desktop" no se reinicia solo, hay que relanzar la app
#        entera para que reconcilie) -----------------------------------------
Write-Host ""
Write-Host "-- Reiniciando Docker Desktop --"
Get-Process | Where-Object { $_.ProcessName -match "Docker Desktop|com\.docker" } | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3
wsl --shutdown
Start-Sleep -Seconds 2
$dockerExe = "$env:LOCALAPPDATA\Programs\DockerDesktop\Docker Desktop.exe"
if (Test-Path $dockerExe) {
    Start-Process $dockerExe
} else {
    Write-Host "AVISO: no se encontro Docker Desktop.exe en la ruta esperada -- arrancalo a mano."
}

# --- 5. Esperar a que el daemon responda, y levantar el stack ---------------
Write-Host ""
Write-Host "-- Esperando a que Docker responda (hasta ~2 min) --"
$ready = $false
for ($i = 0; $i -lt 24; $i++) {
    docker ps *> $null
    if ($LASTEXITCODE -eq 0) { $ready = $true; break }
    Start-Sleep -Seconds 5
}

if (-not $ready) {
    Write-Host "AVISO: Docker no respondio a tiempo. Espera un poco mas y luego ejecuta 'docker compose up -d' a mano desde el repo."
    exit 1
}

Write-Host ""
Write-Host "-- Levantando el stack (docker compose up -d) --"
Push-Location $ProjectRoot
docker compose up -d
Pop-Location

Write-Host ""
Write-Host "Listo."
