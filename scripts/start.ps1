# Arranca el stack completo (crea o reutiliza los contenedores).
$ProjectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "qbt-nativo.ps1")
Push-Location $ProjectRoot
try {
    docker compose up -d
    Start-QbtNativo
} finally {
    Pop-Location
}
