# Lanza el instalador dockerizado (development/specs/005-instalador-interactivo.md).
#
# Importante: se pasa el nombre de proyecto de Compose explicito
# (COMPOSE_PROJECT_NAME) para que el "docker compose up" que el propio
# instalador ejecuta DENTRO de su contenedor cree los servicios bajo el
# mismo proyecto que usarias tu al ejecutar "docker compose up" a mano
# desde esta carpeta -- si no, al montarse en /repo dentro del
# contenedor, Compose inferiria el nombre "repo" en vez del real, y
# crearia un stack duplicado/desconectado del tuyo.
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$ProjectName = (Split-Path -Leaf $ProjectRoot).ToLower() -replace '[^a-z0-9_-]', ''

# Deteccion de la IP LAN: solo se puede hacer desde el host (dentro del
# contenedor del instalador no hay forma fiable, ve la red de Docker, no
# la del PC). Heuristica: el adaptador que esta Up Y tiene puerta de
# enlace por defecto -- es el que de verdad da salida a la LAN/Internet,
# a diferencia de adaptadores de VPN/virtuales que no siempre la tienen.
# Se pasa como sugerencia (el instalador la muestra como valor por
# defecto, pulsar Enter la acepta) -- nunca se fuerza sin que el usuario
# la confirme, por si hay varios adaptadores y el elegido no es el
# correcto.
$DetectedIp = (Get-NetIPConfiguration -ErrorAction SilentlyContinue |
    Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq "Up" } |
    Select-Object -First 1 -ExpandProperty IPv4Address -ErrorAction SilentlyContinue).IPAddress

Push-Location $ProjectRoot
try {
    # Docker Compose interpola TODO el docker-compose.yml (todos los
    # servicios, no solo "installer") antes de arrancar nada -- sin un
    # .env presente, DATA_ROOT/CONFIG_ROOT quedan vacios y Compose ni
    # siquiera consigue parsear el fichero ("invalid spec: :/data").
    # Un .env de plantilla (aunque tenga rutas que no son las tuyas
    # todavia) es suficiente para que Compose arranque el contenedor del
    # instalador -- el propio instalador lo sobrescribe con tus valores
    # reales antes de arrancar el resto del stack.
    if (-not (Test-Path ".env")) {
        Copy-Item ".env.example" ".env"
        Write-Output "(.env no existia -- copiado desde .env.example como placeholder; el instalador te pedira los valores reales)"
    }
    docker compose run --rm -it -e COMPOSE_PROJECT_NAME=$ProjectName -e HOST_LAN_IP_DETECTED=$DetectedIp installer
} finally {
    Pop-Location
}
