# Borra descargas "fantasma": las que siguen en torrents\ pero ya no hacen
# falta (Radarr/Sonarr tienen otra version en la biblioteca, o la pelicula
# ya no esta en Radarr/Sonarr). Enseña la lista y pide confirmacion antes
# de borrar nada. Lo que se ha quedado fuera de Jellyfin, lo reciente y
# las descargas manuales NO se ofrecen (ver pagina "Espacio en disco").
#
#   scripts\borrar-fantasmas.ps1                         lista y pregunta
#   scripts\borrar-fantasmas.ps1 -SoloVer                solo lista
#   scripts\borrar-fantasmas.ps1 -IncluirDesconocidas    ofrece tambien descargas manuales
param(
    [switch]$SoloVer,
    [switch]$IncluirDesconocidas
)
$ProjectRoot = Split-Path -Parent $PSScriptRoot
Push-Location $ProjectRoot
try {
    $extra = @()
    if ($SoloVer) { $extra += "--solo-ver" }
    if ($IncluirDesconocidas) { $extra += "--incluir-desconocidas" }
    docker compose --profile tools run --rm --build disk-clean @extra
} finally {
    Pop-Location
}
