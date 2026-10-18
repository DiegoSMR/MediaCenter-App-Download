#!/bin/bash
# =============================================================================
# backup.sh — copia periódica de lo que de verdad no se puede reconstruir
# solo con "git clone": ${CONFIG_ROOT} (bases de datos de Radarr/Sonarr,
# historial de Seerr, ajustes de qBittorrent, etc.) y ".env" (rutas de
# esta máquina, no versionado a propósito). docker-compose.yml/bootstrap/
# scripts NO se copian aquí: ya están en el propio repo git, que es su
# backup real (con historial completo, además).
#
# Contenedor de larga duración (restart: unless-stopped), no de un solo
# uso como bootstrap -- hace una copia al arrancar y luego se duerme en
# bucle cada $BACKUP_INTERVAL_HOURS horas.
# =============================================================================
set -uo pipefail

INTERVAL_H="${BACKUP_INTERVAL_HOURS:-24}"

log() { echo "[backup] $*"; }

run_backup() {
  local ts
  ts=$(date -Iseconds)
  log "Iniciando backup (${ts})..."

  mkdir -p /dest/config
  # --delete: si algo se borro en origen (p.ej. quitaste un servicio), que
  # tambien desaparezca del backup -- si no, /dest crece para siempre con
  # basura de configs que ya no existen.
  rsync -a --delete /source/config/ /dest/config/

  if [ -f /source/.env ]; then
    cp /source/.env /dest/.env
  else
    log "AVISO: no se encontro .env en origen, no se copio."
  fi

  echo "$ts" > /dest/.last-backup
  log "Backup completado -> ${BACKUP_ROOT_LABEL:-/dest}"
}

log "========================================================================"
log "backup arrancado. Intervalo: cada ${INTERVAL_H}h."
log "Origen: \${CONFIG_ROOT} + .env  |  Destino: \${BACKUP_ROOT}"
log ""
log "OJO -- limitacion conocida: esto es una copia de ficheros en caliente,"
log "sin coordinacion con las apps que estan escribiendo en sus bases de"
log "datos SQLite (Radarr/Sonarr/etc.) mientras se copian. El riesgo de"
log "pillar un fichero a medio escribir es bajo pero no cero. Para una"
log "garantia total haria falta parar los contenedores antes de cada copia,"
log "lo cual supondria caidas periodicas del stack -- no se ha hecho ese"
log "cambio, se ha preferido disponibilidad continua a backups perfectos."
log "========================================================================"

while true; do
  run_backup
  sleep "$((INTERVAL_H * 3600))"
done
