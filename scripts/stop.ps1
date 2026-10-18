# Detiene y elimina los contenedores del stack (la configuración y los datos
# en D:\MEDIA no se tocan, viven fuera de los contenedores).
$ProjectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "qbt-nativo.ps1")
Push-Location $ProjectRoot
try {
    Stop-QbtNativo
    docker compose down
} finally {
    Pop-Location
}
