#!/bin/bash
# =============================================================================
# install.sh — Asistente de instalación dockerizado. Corre DENTRO de un
# contenedor (imagen ligera: alpine+bash+curl+jq+docker-cli), con la raíz
# del repo y /var/run/docker.sock montados, para poder generar .env,
# arrancar el resto del stack, y darte el informe de qué queda a mano --
# todo en un solo `docker compose run --rm -it installer`.
#
# Ver development/specs/005-instalador-interactivo.md para el diseño
# completo y por qué "dockerizado" implica montar docker.sock (control de
# escritura sobre Docker mientras corre este contenedor de un solo uso,
# igual que "bootstrap").
# =============================================================================
set -uo pipefail

REPO=/repo
ENV_FILE="$REPO/.env"

echo ""
echo "=================================================================="
echo " Instalador de MediaCenter"
echo "=================================================================="
echo ""

# ---------------------------------------------------------------------------
# 1. .env ya existe? -- no lo pisamos sin que lo confirmes explicitamente.
# ---------------------------------------------------------------------------
if [ -f "$ENV_FILE" ]; then
  echo "Ya existe un .env en este repo."
  read -rp "¿Quieres regenerarlo desde cero? Escribe 'si' para confirmar, cualquier otra cosa para conservarlo tal cual: " confirm
  if [ "$confirm" != "si" ]; then
    echo "Conservando el .env actual. Saltando a arrancar el stack."
    SKIP_ENV=1
  fi
fi

if [ "${SKIP_ENV:-0}" != "1" ]; then
  echo ""
  echo "-- Rutas (se guardan tal cual escribas, con barras / no \\) --"
  read -rp "DATA_ROOT (ej. D:/MEDIA/data): " data_root
  read -rp "CONFIG_ROOT (ej. D:/MEDIA/config): " config_root
  read -rp "BACKUP_ROOT (ej. D:/MEDIA/backup): " backup_root

  echo ""
  echo "-- IP LAN de este PC --"
  if [ -n "${HOST_LAN_IP_DETECTED:-}" ]; then
    echo "Detectada automaticamente desde el host: ${HOST_LAN_IP_DETECTED}"
    echo "(el adaptador de red activo con puerta de enlace por defecto)."
    read -rp "HOST_LAN_IP [${HOST_LAN_IP_DETECTED}]: " host_lan_ip
    host_lan_ip="${host_lan_ip:-$HOST_LAN_IP_DETECTED}"
  else
    echo "No se pudo detectar sola. En Windows: abre PowerShell y ejecuta"
    echo "'ipconfig', busca la 'Direccion IPv4' de tu adaptador de red"
    echo "(Ethernet o Wi-Fi), algo como 192.168.1.XXX."
    read -rp "HOST_LAN_IP: " host_lan_ip
  fi

  echo ""
  read -rp "PUID [1000]: " puid
  puid="${puid:-1000}"
  read -rp "PGID [1000]: " pgid
  pgid="${pgid:-1000}"
  read -rp "TZ [Europe/Madrid]: " tz
  tz="${tz:-Europe/Madrid}"

  cat > "$ENV_FILE" <<EOF
DATA_ROOT=${data_root}
CONFIG_ROOT=${config_root}
BACKUP_ROOT=${backup_root}
HOST_LAN_IP=${host_lan_ip}
PUID=${puid}
PGID=${pgid}
TZ=${tz}
EOF
  echo ""
  echo ".env generado."
fi

# Recarga las variables por si veniamos de generarlas ahora mismo
# (para el resto del script, p.ej. el informe final).
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

# ---------------------------------------------------------------------------
# 1b. Verificar que DATA_ROOT soporta hardlinks -- Radarr/Sonarr dependen de
#     esto para importar sin duplicar cada descarga (ver CLAUDE.md, seccion
#     "Single /data mount"). Si DATA_ROOT esta repartido entre discos/
#     filesystems distintos (p.ej. una unidad de red, o una carpeta movida a
#     otro disco despues), el hardlink falla en silencio y Radarr/Sonarr
#     COPIAN el fichero entero en su lugar -- cada descarga ocupa el doble,
#     sin ningun error visible hasta que alguien nota el disco lleno (visto
#     de verdad en una migracion real, ver
#     development/history/024-instalador-espacio-disco.md). Se prueba con un
#     contenedor efimero via el mismo docker.sock que ya usa este instalador,
#     montando el DATA_ROOT real tal cual lo interpretaria docker-compose.yml.
# ---------------------------------------------------------------------------
echo ""
echo "-- Comprobando que DATA_ROOT soporta hardlinks (necesario para que"
echo "   Radarr/Sonarr no dupliquen cada descarga en disco) --"
hardlink_result=$(docker run --rm -v "${DATA_ROOT}:/data-test" alpine:3.20 sh -c '
  set -e
  mkdir -p /data-test/.hardlink-test/a /data-test/.hardlink-test/b
  echo probe > /data-test/.hardlink-test/a/probe.txt
  if ln /data-test/.hardlink-test/a/probe.txt /data-test/.hardlink-test/b/probe.txt 2>/dev/null; then
    echo HARDLINK_OK
  else
    echo HARDLINK_FAIL
  fi
  rm -rf /data-test/.hardlink-test
' 2>/dev/null || echo "HARDLINK_ERROR")

case "$hardlink_result" in
  *HARDLINK_OK*)
    echo "OK -- los hardlinks funcionan en DATA_ROOT."
    ;;
  *HARDLINK_FAIL*)
    echo ""
    echo "!! AVISO IMPORTANTE !!"
    echo "Los hardlinks NO funcionan en '${DATA_ROOT}'. Esto significa que"
    echo "Radarr/Sonarr COPIARAN cada fichero entero al importar en vez de"
    echo "enlazarlo -- cada descarga ocupara el DOBLE de espacio en disco,"
    echo "sin ningun error visible en ninguna app."
    echo "Causa tipica: DATA_ROOT reparte 'torrents' y 'media' entre discos o"
    echo "filesystems distintos (p.ej. una unidad de red, o una ruta movida a"
    echo "otro disco despues). Revisa CLAUDE.md, seccion 'Single /data mount'."
    read -rp "¿Continuar de todas formas? [s/N]: " continue_anyway
    if [ "${continue_anyway:-n}" != "s" ] && [ "${continue_anyway:-n}" != "S" ]; then
      echo "Instalacion cancelada. Corrige DATA_ROOT y vuelve a lanzar el instalador."
      exit 1
    fi
    ;;
  *)
    echo "AVISO: no se pudo comprobar el hardlink (¿DATA_ROOT no existe todavia"
    echo "o no es accesible desde Docker?). Se continua sin bloquear -- si el"
    echo "problema persiste tras el primer arranque, revisalo a mano."
    ;;
esac

# ---------------------------------------------------------------------------
# 2. Arrancar el stack
# ---------------------------------------------------------------------------
echo ""
echo "-- Arrancando el stack (docker compose up -d --build) --"
echo "Esto puede tardar 1-2 minutos la primera vez."
cd "$REPO" || exit 1
docker compose up -d --build

echo ""
echo "Esperando a que 'bootstrap' termine su auto-cableado..."
for _ in $(seq 1 60); do
  status=$(docker inspect -f '{{.State.Status}}' bootstrap 2>/dev/null || echo "")
  if [ "$status" = "exited" ]; then
    break
  fi
  sleep 5
done
exit_code=$(docker inspect -f '{{.State.ExitCode}}' bootstrap 2>/dev/null || echo "?")
if [ "$exit_code" = "0" ]; then
  echo "bootstrap completado correctamente."
else
  echo "AVISO: bootstrap no terminó con éxito (código: $exit_code). Revisa 'docker compose logs bootstrap'."
fi

# ---------------------------------------------------------------------------
# 3. Informe final: pasos manuales pendientes, con la IP real ya rellenada
#    (fuente unica: CONFIGURACION-MANUAL.md, no se duplica su contenido).
# ---------------------------------------------------------------------------
echo ""
echo "=================================================================="
echo " Instalación automática completada. Esto queda a mano:"
echo "=================================================================="
if [ -f "$REPO/CONFIGURACION-MANUAL.md" ]; then
  sed "s/<IP>/${HOST_LAN_IP:-<IP>}/g" "$REPO/CONFIGURACION-MANUAL.md"
else
  echo "(No se encontró CONFIGURACION-MANUAL.md en el repo -- consulta el README.)"
fi

echo ""
echo "=================================================================="
echo " Modo de consumo de recursos"
echo "=================================================================="
echo "Este instalador no ajusta el techo de memoria de WSL2 (es una"
echo "configuración de Windows, fuera del alcance de un contenedor)."
echo "Para eso, desde PowerShell en el host:"
echo "  scripts\\set-mode.ps1 -Mode Minimo|Default|Rendimiento"
echo ""
echo "=================================================================="
echo " Espacio en disco de WSL2/Docker Desktop"
echo "=================================================================="
echo "El disco virtual de WSL2 (ext4.vhdx) solo crece, nunca se encoge"
echo "solo -- aunque borres imagenes/contenedores/datos, ese fichero en"
echo "tu disco de Windows sigue ocupando lo mismo. Con meses de uso puede"
echo "acumular varios GB de mas sin que se note desde dentro de Docker."
echo "Si el disco de Windows se te queda corto con el tiempo, de vez en"
echo "cuando (con Docker Desktop cerrado) desde PowerShell:"
echo "  wsl --shutdown"
echo "  Optimize-VHD -Path \"\$env:LOCALAPPDATA\\Docker\\wsl\\data\\ext4.vhdx\" -Mode Full"
echo "(el comando Optimize-VHD necesita el modulo Hyper-V habilitado; si no"
echo "lo tienes, tambien vale comprimir/recrear el disco desde Docker"
echo "Desktop > Troubleshoot > Clean/Purge data, como ultimo recurso)."
echo ""
echo "Instalación terminada."
