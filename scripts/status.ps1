# Muestra el estado de todos los contenedores del stack.
$ProjectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "qbt-nativo.ps1")
Push-Location $ProjectRoot
try {
    docker compose ps
    Show-QbtNativo
} finally {
    Pop-Location
}
