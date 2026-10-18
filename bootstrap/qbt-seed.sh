#!/bin/sh
# =============================================================================
# qbt-seed.sh — Se ejecuta UNA VEZ antes del primer arranque de qBittorrent,
# para que tenga usuario/contraseña conocidos desde el segundo cero (si no,
# qBittorrent genera una contraseña aleatoria distinta cada vez, lo que
# impediría que "bootstrap" pudiera autenticarse). admin / adminadmin.
#
# CAMBIA esta contraseña desde la WebUI tras tu primer login.
# =============================================================================
set -eu

CONF_DIR="/config/qBittorrent"
CONF_FILE="$CONF_DIR/qBittorrent.conf"

mkdir -p "$CONF_DIR"

# /incomplete-fast es un bind mount de ${DATA_ROOT}/torrents/incomplete
# (ver docker-compose.yml) donde este chown ya no aplica en la practica
# (NTFS via WSL2 no respeta permisos Unix reales), pero se deja: es
# inofensivo y protege si alguna vez vuelve a ser un volumen Docker nativo
# (esos los crea Docker como root:root, y qBittorrent corre como
# PUID:PGID, no root). Se corrige SIEMPRE (idempotente), no solo la
# primera vez, por si el volumen/carpeta se recrea.
if [ -d /incomplete-fast ]; then
  chown -R "${PUID:-1000}:${PGID:-1000}" /incomplete-fast
  echo "[qbt-seed] Permisos de /incomplete-fast corregidos."
fi

if [ ! -f "$CONF_FILE" ]; then
  cat > "$CONF_FILE" <<'EOF'
[Preferences]
WebUI\Username=admin
WebUI\Password_PBKDF2="@ByteArray(ARQ77eY1NUZaQsuDHbIMCA==:0WMRkYTUWVT9wVvdDtHAjU9b3b7uB8NR1Gur2hmQCvCDpm39Q+PsJRJPaCU51dEiz+dTzh8qbPsL8WkFljQYFQ==)"

[BitTorrent]
Session\DefaultSavePath=/data/torrents
# Las descargas EN CURSO van a /incomplete-fast, bind mount de
# ${DATA_ROOT}/torrents/incomplete (no volumen nativo de WSL2 -- ver
# docker-compose.yml y development/history/024-instalador-espacio-disco.md
# para el porque). Al completarse, qBittorrent copia el archivo a
# /data/torrents (donde Radarr/Sonarr lo esperan para hardlinkear) y borra
# la copia temporal solo -- sin duplicados.
Session\TempPath=/incomplete-fast
Session\TempPathEnabled=true
# Maximo 10 descargas activas a la vez (antes 5). Sin limite, muchos
# torrents simultaneos se reparten tu ancho de banda (se probo: 18 a la
# vez = ~9MB/s repartidos), pero eso solo pasa con la conexion llena; con
# torrents de pocas fuentes cada uno aporta lo suyo y mas a la vez suman.
# Los torrents lentos no ocupan plaza y el total es 20 (lo aplica tambien
# bootstrap.sh en cada arranque, junto con la lista de trackers extra --
# ver ahi el porque).
Session\QueueingSystemEnabled=true
Session\MaxActiveDownloads=10
Session\MaxActiveUploads=10
Session\MaxActiveTorrents=20
Session\IgnoreSlowTorrentsForQueueing=true
Session\SlowTorrentsDownloadRate=10
Session\SlowTorrentsUploadRate=5
# Seeding sin limite consume ancho de banda/CPU/disco indefinidamente
# (visto en Task Manager: vmmemWSL con uso alto incluso sin descargas
# nuevas). Subida limitada a 2MB/s (KiB/s en este fichero) y cada
# torrent deja de sembrar solo a las 72h (4320 min) de completarse,
# pasando a pausado (no se borra).
Session\GlobalUPSpeedLimit=2048
Session\GlobalMaxSeedingMinutes=4320
# Fijo a 6881 para que coincida EXACTO con el puerto publicado en
# docker-compose.yml ("6881:6881"). Si se deja sin fijar, qBittorrent
# elige un puerto propio (p. ej. 21367) que Docker nunca expone, dejando
# la conexion entrante bloqueada sin avisar -> velocidades muy bajas.
Session\Port=6881
# E/S de disco "POSIX-compliant" (pread/pwrite) en vez de la de libtorrent
# 2 por defecto (archivos mapeados en memoria). Sobre el bind mount NTFS de
# Docker Desktop, la de mmap empezo a fallar con "No space left on device"
# en CADA escritura tras llenarse el disco una vez, aun con cientos de GB
# libres (2026-09-29); las escrituras normales funcionaban. Ver
# development/history/032-remove-completed.md.
Session\DiskIOType=Posix
EOF
  echo "[qbt-seed] Credenciales iniciales escritas (admin / adminadmin)."
else
  echo "[qbt-seed] qBittorrent.conf ya existe, no se toca."
fi
