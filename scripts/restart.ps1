# Reinicia los servicios que ya están corriendo (no vuelve a ejecutar el
# cableado de "bootstrap", solo aplica si ya arrancaste el stack antes).
$ProjectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "qbt-nativo.ps1")
Push-Location $ProjectRoot
try {
    Stop-QbtNativo
    docker compose restart
    Start-QbtNativo
} finally {
    Pop-Location
}
