#!/bin/bash
# =============================================================================
# bootstrap.sh — Conecta automáticamente Prowlarr <-> Radarr/Sonarr <->
# qBittorrent, separa categorías movies/tv, desactiva el login dentro de la
# LAN en Radarr/Sonarr/Prowlarr, y regenera Homer + Recyclarr con las API
# keys reales. Se ejecuta UNA VEZ tras el primer arranque (contenedor de un
# solo uso).
#
# Lo que SIGUE siendo manual (no automatizable de forma segura/estable):
#   - Añadir tus indexadores/trackers dentro de Prowlarr (credenciales tuyas)
#   - Asistente inicial de Jellyfin (usuario admin + bibliotecas)
#   - Asistente inicial de Seerr (login con el admin de Jellyfin,
#     conectar Radarr/Sonarr)
# =============================================================================
set -uo pipefail
source /common.sh   # log(), wait_apikey(), jellyfin_connect()

CONF=/hostconfig   # ${CONFIG_ROOT} montado aquí, lectura/escritura
# De .env (spec 039: el instalador pone las que elige el usuario). Por
# defecto, las de qbt-seed.sh (ver README: cambiala tras el primer login).
QBT_USER="${QBT_USER:-admin}"
QBT_PASS="${QBT_PASS:-adminadmin}"
ARR_LOGIN="${ARR_LOGIN:-0}"; MC_USER="${MC_USER:-}"; MC_PASSWORD="${MC_PASSWORD:-}"
QBT_COOKIE=/tmp/qbt_cookie
# Donde esta qBittorrent y como ve el disco (spec 013). Por defecto, el
# contenedor "qbittorrent" (rutas /data/...). Con qBittorrent nativo en
# Windows: QBT_URL=http://host.docker.internal:8080 y QBT_DATA_DIR = el
# DATA_ROOT de Windows (D:/MEDIA/data); ver docker-compose.override.yml.
QBT_URL="${QBT_URL:-http://qbittorrent:8080}"
QBT_DATA_DIR="${QBT_DATA_DIR:-/data}"
QBT_HOST="${QBT_URL#*://}"; QBT_HOST="${QBT_HOST%%:*}"
QBT_PORT="${QBT_URL##*:}"; QBT_PORT="${QBT_PORT%%/*}"

wait_http() {
  local url="$1"
  until curl -sf -o /dev/null "$url"; do
    log "esperando $url ..."
    sleep 3
  done
}

wait_bazarr_apikey() {
  local file="$CONF/bazarr/config/config.yaml"
  log "esperando config.yaml de Bazarr ..."
  until [ -s "$file" ] && grep -qE '^\s*apikey:' "$file"; do
    sleep 3
  done
  grep -m1 -E '^\s*apikey:' "$file" | sed -E 's/^\s*apikey:\s*//'
}

post_json() {
  # post_json <url> <apikey> <json>  -- nunca aborta el script si falla,
  # pero SIEMPRE avisa en el log si la respuesta no es 2xx.
  local code
  code=$(curl -s -o /tmp/resp -w "%{http_code}" -X POST "$1" \
    -H "X-Api-Key: $2" -H "Content-Type: application/json" -d "$3")
  case "$code" in
    2*) ;;
    *)
      # Al volver a ejecutarse, lo que ya existe da 400 ("Should be unique",
      # "already configured as a root folder"): no es un problema, y llenaba
      # el log de AVISOS que tapaban los de verdad (spec 049).
      if [ "$code" = 400 ] && jq -e 'type == "array" and length > 0 and
           all(.[]; (.errorMessage // "") | test("Should be unique|already configured"))' /tmp/resp >/dev/null 2>&1; then
        log "(ya existia: $(echo "$1" | sed 's#.*/api/v[0-9]*/##'))"
      else
        log "AVISO: POST $1 -> HTTP $code: $(cat /tmp/resp)"
      fi ;;
  esac
}

qbt_location() {
  # qbt_location <base_api_url> <apikey>
  # Apunta el cliente qBittorrent de Radarr/Sonarr a QBT_HOST:QBT_PORT en
  # cada arranque (no solo al crearlo), para poder pasar de qBittorrent en
  # Docker a nativo y al reves cambiando solo .env (spec 013). Con
  # qBittorrent nativo informa de rutas Windows (D:\MEDIA\data\torrents\X):
  # un Remote Path Mapping las traduce a /data/torrents/X. Si se vuelve a
  # Docker, se quita. forceSave: no fallar si qBittorrent aun no responde.
  local base="$1" key="$2" id current updated code rp maps
  for id in $(curl -s -H "X-Api-Key: $key" "$base/downloadclient" | jq -r '.[] | select(.implementation=="QBittorrent") | .id'); do
    current=$(curl -s -H "X-Api-Key: $key" "$base/downloadclient/$id")
    updated=$(echo "$current" | jq --arg h "$QBT_HOST" --argjson p "$QBT_PORT" \
      '(.fields[] | select(.name=="host") | .value) = $h | (.fields[] | select(.name=="port") | .value) = $p')
    [ "$updated" = "$(echo "$current" | jq .)" ] && continue
    code=$(curl -s -o /tmp/resp -w "%{http_code}" -X PUT "$base/downloadclient/$id?forceSave=true" \
      -H "X-Api-Key: $key" -H "Content-Type: application/json" -d "$updated")
    case "$code" in
      2*) log "Cliente qBittorrent de $base -> $QBT_HOST:$QBT_PORT" ;;
      *) log "AVISO: PUT $base/downloadclient/$id -> HTTP $code: $(cat /tmp/resp)" ;;
    esac
  done
  maps=$(curl -s -H "X-Api-Key: $key" "$base/remotepathmapping")
  if [ "$QBT_DATA_DIR" = "/data" ]; then
    for id in $(echo "$maps" | jq -r '.[] | select(.localPath=="/data/torrents/") | .id'); do
      curl -s -o /dev/null -X DELETE -H "X-Api-Key: $key" "$base/remotepathmapping/$id"
    done
    return
  fi
  rp="$(echo "$QBT_DATA_DIR" | tr '/' '\\')\\torrents\\"
  echo "$maps" | jq -e --arg h "$QBT_HOST" --arg rp "$rp" 'any(.[]; .host==$h and .remotePath==$rp)' >/dev/null && return
  code=$(jq -n --arg h "$QBT_HOST" --arg rp "$rp" '{host:$h, remotePath:$rp, localPath:"/data/torrents/"}' \
    | curl -s -o /tmp/resp -w "%{http_code}" -X POST -H "X-Api-Key: $key" -H "Content-Type: application/json" \
      --data-binary @- "$base/remotepathmapping")
  case "$code" in
    2*) log "Remote Path Mapping en $base: $rp -> /data/torrents/" ;;
    *) log "AVISO: POST $base/remotepathmapping -> HTTP $code: $(cat /tmp/resp)" ;;
  esac
}

remove_completed() {
  # remove_completed <base_api_url> <apikey>
  # "Remove Completed" + "Remove Failed" en el cliente qBittorrent de
  # Radarr/Sonarr (spec 023). Sin esto, cada torrent se queda en
  # qBittorrent y en torrents/ para siempre; cuando Radarr/Sonarr sustituyen
  # la version de la biblioteca, la descarga vieja queda como "fantasma"
  # (espacio ocupado que Jellyfin no ve). Con esto la retiran ellos solos
  # (torrent + archivos) cuando qBittorrent la para por haber llegado a su
  # limite de compartir (72h, qbt-seed.sh) -- la biblioteca no pierde nada:
  # es un hardlink. Se aplica SIEMPRE (no solo al crear el cliente), para
  # que llegue tambien a instalaciones ya existentes.
  local base="$1" key="$2" id current updated code
  for id in $(curl -s -H "X-Api-Key: $key" "$base/downloadclient" | jq -r '.[] | select(.implementation=="QBittorrent") | .id'); do
    current=$(curl -s -H "X-Api-Key: $key" "$base/downloadclient/$id")
    updated=$(echo "$current" | jq '.removeCompletedDownloads = true | .removeFailedDownloads = true')
    code=$(curl -s -o /tmp/resp -w "%{http_code}" -X PUT "$base/downloadclient/$id" \
      -H "X-Api-Key: $key" -H "Content-Type: application/json" -d "$updated")
    case "$code" in
      2*) ;;
      *) log "AVISO: PUT $base/downloadclient/$id -> HTTP $code: $(cat /tmp/resp)" ;;
    esac
  done
}

no_recycle_bin() {
  # no_recycle_bin <base_api_url> <apikey>
  # Sin papelera en Radarr/Sonarr (spec 026, decision del usuario): lo que
  # se borra o se sustituye al mejorar la calidad se borra del todo al
  # momento, en vez de guardarse 7 dias en /data/recycle-bin (llego a
  # ocupar 683GB). Se aplica SIEMPRE, tambien en instalaciones existentes.
  local base="$1" key="$2" current updated code
  current=$(curl -s -H "X-Api-Key: $key" "$base/config/mediamanagement")
  updated=$(echo "$current" | jq '.recycleBin = ""')
  code=$(curl -s -o /tmp/resp -w "%{http_code}" -X PUT "$base/config/mediamanagement" \
    -H "X-Api-Key: $key" -H "Content-Type: application/json" -d "$updated")
  case "$code" in
    2*) ;;
    *) log "AVISO: PUT $base/config/mediamanagement -> HTTP $code: $(cat /tmp/resp)" ;;
  esac
}

seeders_profile() {
  # seeders_profile <base_api_url> <apikey>
  # Perfil "Mas seeders" (spec 027): elige el release con MAS SEEDERS entre
  # 720p y 1080p. Radarr/Sonarr ordenan por calidad -> puntuacion de
  # formatos -> ... -> seeders (verificado en su DownloadDecisionComparer).
  # Metiendo todas esas calidades en UN grupo empatan en calidad (GetIndex
  # da el mismo indice a todo el grupo) y sin puntuaciones empatan en
  # formatos, asi que decide el numero de seeders. Ojo: los compara por
  # orden de magnitud (log10 redondeado: ~3-30, ~30-300, ~300-3000...);
  # dentro del mismo orden desempata el tamano. Sin mejoras: lo primero
  # que baja se queda. Los topes de tamano (Recyclarr) siguen aplicando.
  # Se crea desde "Any" (existe en toda instalacion) y se reescribe en
  # cada arranque.
  local base="$1" key="$2" any existing body id code
  any=$(curl -s -H "X-Api-Key: $key" "$base/qualityprofile" | jq '[.[] | select(.name=="Any")][0]')
  [ "$any" = "null" ] && { log "AVISO: sin perfil Any en $base, no se crea 'Mas seeders'"; return; }
  body=$(echo "$any" | jq '
    ["HDTV-720p","WEBDL-720p","WEBRip-720p","Bluray-720p","HDTV-1080p","WEBDL-1080p","WEBRip-1080p","Bluray-1080p"] as $sel
    | [.items[] | if .quality then .quality else .items[].quality end] as $q
    | {name: "Mas seeders", upgradeAllowed: false, cutoff: 1001,
       minFormatScore: 0, cutoffFormatScore: 0, minUpgradeFormatScore: 1,
       formatItems: [.formatItems[]? | .score = 0],
       items: ([$q[] | select(.name as $n | $sel | index($n) | not) | {quality: ., items: [], allowed: false}]
               + [{id: 1001, name: "HD 720p/1080p", allowed: true,
                   items: [$q[] | select(.name as $n | $sel | index($n)) | {quality: ., items: [], allowed: true}]}])}
    + (if .language then {language: .language} else {} end)')
  id=$(curl -s -H "X-Api-Key: $key" "$base/qualityprofile" | jq '[.[] | select(.name=="Mas seeders")][0].id // empty')
  if [ -n "$id" ]; then
    code=$(curl -s -o /tmp/resp -w "%{http_code}" -X PUT "$base/qualityprofile/$id" \
      -H "X-Api-Key: $key" -H "Content-Type: application/json" -d "$(echo "$body" | jq --argjson id "$id" '.id = $id')")
  else
    code=$(curl -s -o /tmp/resp -w "%{http_code}" -X POST "$base/qualityprofile" \
      -H "X-Api-Key: $key" -H "Content-Type: application/json" -d "$body")
  fi
  case "$code" in
    2*) ;;
    *) log "AVISO: perfil 'Mas seeders' en $base -> HTTP $code: $(cat /tmp/resp)" ;;
  esac
}

jellyseerr_default_profile() {
  # Seerr (antes Jellyseerr) pide con el perfil "Mas seeders" (spec 027; el antiguo
  # POPULAR se elimino). Solo si Jellyseerr ya paso su asistente (tiene
  # API key); si no responde, no pasa nada. Su API no admite "id" en el
  # cuerpo del PUT (400 "request.body.id is read-only").
  local jkey kind port akey pid servers sid body code
  jkey=$(jq -r '.main.apiKey // empty' "$CONF/jellyseerr/settings.json" 2>/dev/null)
  [ -z "$jkey" ] && return
  for kind in radarr sonarr; do
    if [ "$kind" = radarr ]; then port=7878; akey="$RADARR_KEY"; else port=8989; akey="$SONARR_KEY"; fi
    pid=$(curl -s -H "X-Api-Key: $akey" "http://$kind:$port/api/v3/qualityprofile" | jq '[.[] | select(.name=="Mas seeders")][0].id // empty')
    servers=$(curl -s -m 10 -H "X-Api-Key: $jkey" "http://jellyseerr:5055/api/v1/settings/$kind") || continue
    [ -z "$pid" ] && continue
    for sid in $(echo "$servers" | jq -r '.[]? | select(.is4k | not) | .id'); do
      body=$(echo "$servers" | jq --argjson sid "$sid" --argjson pid "$pid" \
        '.[] | select(.id == $sid) | del(.id) | .activeProfileId = $pid | .activeProfileName = "Mas seeders"')
      code=$(curl -s -o /tmp/resp -w "%{http_code}" -X PUT "http://jellyseerr:5055/api/v1/settings/$kind/$sid" \
        -H "X-Api-Key: $jkey" -H "Content-Type: application/json" -d "$body")
      case "$code" in
        2*) ;;
        *) log "AVISO: perfil de Jellyseerr ($kind) -> HTTP $code: $(cat /tmp/resp)" ;;
      esac
    done
  done
}

set_arr_auth() {
  # set_arr_auth <base_api_url> <apikey>
  # Login de Radarr/Sonarr/Prowlarr, lo elige el usuario al instalar
  # (ARR_LOGIN en .env, 2026-10-16):
  # - ARR_LOGIN=1: usuario y contrasena, los mismos que Jellyfin/Seerr
  #   (MC_USER/MC_PASSWORD), en todas partes. La API key sigue valiendo, asi
  #   que Homer, disk-report, Seerr y Bazarr no notan nada.
  # - si no (por defecto): sin login. Metodo "external" = "la autenticacion
  #   la hace otro", asi que la app nunca pide usuario. Antes era
  #   "disabledForLocalAddresses", pero Radarr 6.4.4 / Sonarr 4.0.20 /
  #   Prowlarr 2.6 (sep 2026) lo rechazan con 400 si "Allowed Hosts" esta
  #   vacio, y rellenarlo devuelve 400 "Invalid Hostname" a cualquier nombre
  #   o IP que no este en la lista ("*" no se admite): con DHCP, cambiar la
  #   IP del PC dejaria las apps inaccesibles. Desde Docker Desktop toda
  #   conexion llega desde la red interna, asi que "local" ya era casi todo.
  #   Nada de esto se publica en el router (solo el puerto de torrents).
  local base="$1" key="$2" current updated code
  current=$(curl -s -H "X-Api-Key: $key" "$base/config/host")
  if [ "$ARR_LOGIN" = "1" ] && [ -n "$MC_USER" ] && [ -n "$MC_PASSWORD" ]; then
    updated=$(echo "$current" | jq --arg u "$MC_USER" --arg p "$MC_PASSWORD" \
      '.authenticationRequired = "enabled" | .authenticationMethod = "forms" | .allowedHosts = ""
       | .username = $u | .password = $p | .passwordConfirmation = $p')
  else
    [ "$ARR_LOGIN" = "1" ] && log "AVISO: ARR_LOGIN=1 pero faltan MC_USER/MC_PASSWORD en .env: se deja sin login"
    updated=$(echo "$current" | jq '.authenticationRequired = "enabled" | .authenticationMethod = "external" | .allowedHosts = ""')
  fi
  # Log "info", no "debug" (el que traian): con debug la busqueda
  # interactiva de Radarr tardaba 24,5 s y se quedaba "cargando" si la app
  # estaba ocupada; con info, 3-4 s (medido 2026-10-16). Debug escribe miles
  # de lineas por busqueda al disco, a traves del bind mount de Docker.
  updated=$(echo "$updated" | jq '.logLevel = "info"')
  code=$(curl -s -o /tmp/resp -w "%{http_code}" -X PUT "$base/config/host" \
    -H "X-Api-Key: $key" -H "Content-Type: application/json" -d "$updated")
  case "$code" in
    2*) ;;
    *) log "AVISO: PUT $base/config/host -> HTTP $code: $(cat /tmp/resp)" ;;
  esac
}

# ---------------------------------------------------------------------------
# 1. Esperar a que las apps generen su config.xml con ApiKey
# ---------------------------------------------------------------------------
RADARR_KEY=$(wait_apikey "$CONF/radarr/config.xml" "Radarr")
SONARR_KEY=$(wait_apikey "$CONF/sonarr/config.xml" "Sonarr")
PROWLARR_KEY=$(wait_apikey "$CONF/prowlarr/config.xml" "Prowlarr")

wait_http "http://radarr:7878/ping"
wait_http "http://sonarr:8989/ping"
wait_http "http://prowlarr:9696/ping"
wait_http "$QBT_URL"

log "API keys detectadas. Radarr=${RADARR_KEY:0:6}... Sonarr=${SONARR_KEY:0:6}... Prowlarr=${PROWLARR_KEY:0:6}..."

# ---------------------------------------------------------------------------
# 2. qBittorrent: categorias radarr/tv-sonarr con su carpeta (torrents/movies, torrents/tv)
# ---------------------------------------------------------------------------
log "Autenticando en qBittorrent para crear categorías..."
curl -s -c "$QBT_COOKIE" --data-urlencode "username=$QBT_USER" --data-urlencode "password=$QBT_PASS" \
  "$QBT_URL/api/v2/auth/login" >/dev/null

# Las categorias que de verdad usan Radarr/Sonarr son "radarr" y
# "tv-sonarr" (sus nombres por defecto: hasta 2026-10-16 se les mandaba
# "category" en vez de movieCategory/tvCategory y lo ignoraban). No se
# cambian a movies/tv: Radarr/Sonarr siguen sus descargas por categoria y
# lo que ya estuviera bajando o compartiendo quedaria huerfano (sin
# importar ni limpiar). Se les da carpeta; antes no tenian y todo caia
# suelto en torrents/. createCategory falla si ya existe, editCategory no.
for c in "radarr movies" "tv-sonarr tv"; do
  set -- $c
  log "Categoria '$1' -> $QBT_DATA_DIR/torrents/$2 ..."
  for op in createCategory editCategory; do
    curl -s -b "$QBT_COOKIE" -X POST "$QBT_URL/api/v2/torrents/$op" \
      --data-urlencode "category=$1" --data-urlencode "savePath=$QBT_DATA_DIR/torrents/$2" >/dev/null
  done
done

# Cola y trackers (2026-09-29). Visto en vivo: 19 descargas en cola
# mientras las 5 plazas las ocupaban torrents con 1 seeder, y 5 torrents
# compartiendo sin subir nada gastaban plazas del total. Con
# dont_count_slow_torrents los que no llegan al umbral (10 KiB/s bajada, 5
# de subida, durante 60 s) dejan de ocupar plaza y arranca el siguiente.
# Descargas activas: 10 (antes 5, "mas a la vez se reparten el ancho de
# banda"). Eso solo pasa con la conexion llena, y aqui no lo esta: 5
# activas sumaban 117 KB/s en 1 Gbps, cada una limitada por sus pocas
# fuentes (y sin conexiones entrantes por el CGNAT), asi que mas a la vez
# SUMAN. No ilimitado: cada una escribe por el puente 9p de WSL2 al NTFS,
# que ya se ha colgado alguna vez. El total sube a 20 para que lo que
# comparte no las bloquee. Trackers: la mayoria de los de un torrent
# publico estan muertos (15 de 23 en uno de ejemplo); qBittorrent anade a
# cada torrent nuevo la lista "best" de ngosang/trackerslist, que descarga
# y actualiza el mismo. Se aplica en cada arranque (setPreferences), no
# solo en la instalacion como qbt-seed.sh.
log "Ajustando la cola de qBittorrent (los lentos no ocupan plaza) y trackers extra..."
code=$(curl -s -o /tmp/resp -w "%{http_code}" -b "$QBT_COOKIE" -X POST "$QBT_URL/api/v2/app/setPreferences" \
  --data-urlencode 'json={"queueing_enabled":true,"max_active_downloads":10,"max_active_uploads":10,"max_active_torrents":20,
    "dont_count_slow_torrents":true,"slow_torrent_dl_rate_threshold":10,"slow_torrent_ul_rate_threshold":5,"slow_torrent_inactive_timer":60,
    "add_trackers_from_url_enabled":true,"add_trackers_url":"https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_best.txt",
    "auto_tmm_enabled":true,"category_changed_tmm_enabled":false}')
# auto_tmm_enabled: los torrents nuevos van a la carpeta de su categoria
# (en modo manual, el de serie, la categoria no cambia la carpeta).
# category_changed_tmm_enabled=false: si cambia la carpeta de una
# categoria, sus torrents pasan a manual en vez de moverse.
case "$code" in
  2*) ;;
  *) log "AVISO: setPreferences qBittorrent -> HTTP $code: $(cat /tmp/resp)" ;;
esac

# Descargas propias (magnet/.torrent abiertos a mano, sin categoria) en
# data/descargas, no en torrents/ (2026-10-18). En torrents/, el panel de
# disco las tomaba por "fantasma, recuperable" y ofrecia borrarlas (un juego,
# por ejemplo). Radarr/Sonarr no cambian: usan sus categorias. Solo con
# qBittorrent nativo: el contenedor solo monta /data/torrents.
# save_path_changed_tmm_enabled=false: lo que ya estaba no se mueve.
if [ "$QBT_DATA_DIR" != "/data" ]; then
  log "Descargas sin categoria -> $QBT_DATA_DIR/descargas ..."
  code=$(curl -s -o /tmp/resp -w "%{http_code}" -b "$QBT_COOKIE" -X POST "$QBT_URL/api/v2/app/setPreferences" \
    --data-urlencode "json={\"save_path\":\"$QBT_DATA_DIR/descargas\",\"save_path_changed_tmm_enabled\":false}")
  case "$code" in
    2*) ;;
    *) log "AVISO: setPreferences save_path -> HTTP $code: $(cat /tmp/resp)" ;;
  esac
fi

# ---------------------------------------------------------------------------
# 3. Cliente de descargas (qBittorrent) en Radarr y Sonarr, con su categoría
# ---------------------------------------------------------------------------
log "Configurando qBittorrent como cliente de descargas en Radarr (categoria radarr)..."
post_json "http://radarr:7878/api/v3/downloadclient" "$RADARR_KEY" '{
  "enable": true, "protocol": "torrent", "priority": 1,
  "name": "qBittorrent", "implementation": "QBittorrent",
  "configContract": "QBittorrentSettings",
  "fields": [
    {"name":"host","value":"'"$QBT_HOST"'"},
    {"name":"port","value":'"$QBT_PORT"'},
    {"name":"username","value":"'"$QBT_USER"'"},
    {"name":"password","value":"'"$QBT_PASS"'"},
    {"name":"movieCategory","value":"radarr"}
  ]
}' >/dev/null

log "Configurando qBittorrent como cliente de descargas en Sonarr (categoria tv-sonarr)..."
post_json "http://sonarr:8989/api/v3/downloadclient" "$SONARR_KEY" '{
  "enable": true, "protocol": "torrent", "priority": 1,
  "name": "qBittorrent", "implementation": "QBittorrent",
  "configContract": "QBittorrentSettings",
  "fields": [
    {"name":"host","value":"'"$QBT_HOST"'"},
    {"name":"port","value":'"$QBT_PORT"'},
    {"name":"username","value":"'"$QBT_USER"'"},
    {"name":"password","value":"'"$QBT_PASS"'"},
    {"name":"tvCategory","value":"tv-sonarr"}
  ]
}' >/dev/null

log "Activando Remove Completed/Failed en el cliente qBittorrent de Radarr y Sonarr..."
remove_completed "http://radarr:7878/api/v3" "$RADARR_KEY"
remove_completed "http://sonarr:8989/api/v3" "$SONARR_KEY"

log "Apuntando Radarr y Sonarr a qBittorrent en $QBT_URL..."
qbt_location "http://radarr:7878/api/v3" "$RADARR_KEY"
qbt_location "http://sonarr:8989/api/v3" "$SONARR_KEY"

log "Desactivando la papelera de Radarr y Sonarr (borrado definitivo)..."
no_recycle_bin "http://radarr:7878/api/v3" "$RADARR_KEY"
no_recycle_bin "http://sonarr:8989/api/v3" "$SONARR_KEY"

log "Creando/actualizando el perfil 'Mas seeders' en Radarr y Sonarr..."
seeders_profile "http://radarr:7878/api/v3" "$RADARR_KEY"
seeders_profile "http://sonarr:8989/api/v3" "$SONARR_KEY"
jellyseerr_default_profile

# ---------------------------------------------------------------------------
# 4. Carpetas raíz de la biblioteca
# ---------------------------------------------------------------------------
log "Configurando carpeta raíz de películas..."
post_json "http://radarr:7878/api/v3/rootfolder" "$RADARR_KEY" '{"path":"/data/media/movies"}' >/dev/null

log "Configurando carpeta raíz de series..."
post_json "http://sonarr:8989/api/v3/rootfolder" "$SONARR_KEY" '{"path":"/data/media/tv"}' >/dev/null

# ---------------------------------------------------------------------------
# 5. Prowlarr -> Radarr / Sonarr: sync automático de indexadores
# ---------------------------------------------------------------------------
log "Conectando Prowlarr con Radarr..."
post_json "http://prowlarr:9696/api/v1/applications" "$PROWLARR_KEY" '{
  "name": "Radarr", "implementation": "Radarr", "configContract": "RadarrSettings",
  "syncLevel": "fullSync",
  "fields": [
    {"name":"prowlarrUrl","value":"http://prowlarr:9696"},
    {"name":"baseUrl","value":"http://radarr:7878"},
    {"name":"apiKey","value":"'"$RADARR_KEY"'"}
  ]
}' >/dev/null

log "Conectando Prowlarr con Sonarr..."
post_json "http://prowlarr:9696/api/v1/applications" "$PROWLARR_KEY" '{
  "name": "Sonarr", "implementation": "Sonarr", "configContract": "SonarrSettings",
  "syncLevel": "fullSync",
  "fields": [
    {"name":"prowlarrUrl","value":"http://prowlarr:9696"},
    {"name":"baseUrl","value":"http://sonarr:8989"},
    {"name":"apiKey","value":"'"$SONARR_KEY"'"}
  ]
}' >/dev/null

# ---------------------------------------------------------------------------
# 5b. Minimo de seeders: filtra releases casi muertos (no existe un "mas
#     popular" real en Radarr/Sonarr, ver README -- esto es lo mas cercano
#     y si funciona de verdad). Se aplica en el App Profile "Standard" de
#     Prowlarr (id 1), asi que cubre Radarr y Sonarr a la vez.
# ---------------------------------------------------------------------------
log "Configurando minimo de 5 seeders en Prowlarr (App Profile Standard)..."
code=$(curl -s -o /tmp/resp -w "%{http_code}" -X PUT "http://prowlarr:9696/api/v1/appprofile/1" \
  -H "X-Api-Key: $PROWLARR_KEY" -H "Content-Type: application/json" \
  -d '{"id":1,"name":"Standard","enableRss":true,"enableAutomaticSearch":true,"enableInteractiveSearch":true,"minimumSeeders":5}')
case "$code" in
  2*) ;;
  *) log "AVISO: PUT appprofile -> HTTP $code: $(cat /tmp/resp)" ;;
esac

# Mas indexadores y FlareSolverr (spec 052): una vez por instalacion.
prowlarr_extra_indexers "$PROWLARR_KEY"

# ---------------------------------------------------------------------------
# 6. Login (sin login, o el del instalador: ARR_LOGIN) y log "info" de Radarr/Sonarr/Prowlarr
# ---------------------------------------------------------------------------
log "Login de Radarr (ARR_LOGIN=${ARR_LOGIN:-0})..."
set_arr_auth "http://radarr:7878/api/v3" "$RADARR_KEY"

log "Login de Sonarr (ARR_LOGIN=${ARR_LOGIN:-0})..."
set_arr_auth "http://sonarr:8989/api/v3" "$SONARR_KEY"

log "Login de Prowlarr (ARR_LOGIN=${ARR_LOGIN:-0})..."
set_arr_auth "http://prowlarr:9696/api/v1" "$PROWLARR_KEY"

# ---------------------------------------------------------------------------
# 6b. Bazarr: perfiles de idioma + conexion a Radarr/Sonarr.
# ---------------------------------------------------------------------------
BAZARR_KEY=$(wait_bazarr_apikey)
log "esperando http://bazarr:6767/api/system/status (con API key, Bazarr exige auth incluso ahi) ..."
until curl -sf -o /dev/null -H "X-API-KEY: $BAZARR_KEY" "http://bazarr:6767/api/system/status"; do
  sleep 3
done
# "hi":"False" en cada item excluye subtitulos para sordos (hearing-impaired)
# de la busqueda -- confirmado 2026-08-31 que asi debe quedar en ambos
# perfiles, no solo "no exigir HI" sino no traerlo nunca.
#
# Bazarr guarda los perfiles en su base de datos y solo los lee de los
# campos "languages-profiles" y "languages-enabled" (api/system/settings.py).
# Hasta 2026-10-16 se mandaba "settings-general-languages_profiles": 200 y
# no creaba nada, asi que tras el instalador Bazarr no tenia perfiles y no
# buscaba subtitulos de nada. OJO: "languages-profiles" BORRA los perfiles
# que no vayan en la lista, asi que se mandan los que ya hay + los nuestros
# que falten (por nombre, con un profileId libre); nunca se quita ninguno.
log "Creando perfiles de idioma en Bazarr (ENGLISH, ENGLISH + SPANISH) si faltan..."
BZ_CREATED=0
BZ_OURS='[{"name":"ENGLISH","cutoff":null,"items":[{"id":1,"language":"en","audio_exclude":"False","audio_only_include":"False","hi":"False","forced":"False"}],"mustContain":[],"mustNotContain":[],"originalFormat":0,"tag":null},{"name":"ENGLISH + SPANISH","cutoff":null,"items":[{"id":1,"language":"en","audio_exclude":"False","audio_only_include":"False","hi":"False","forced":"False"},{"id":2,"language":"es","audio_exclude":"False","audio_only_include":"False","hi":"False","forced":"False"}],"mustContain":[],"mustNotContain":[],"originalFormat":0,"tag":null}]'
bz_existing=$(curl -s -H "X-API-KEY: $BAZARR_KEY" "http://bazarr:6767/api/system/languages/profiles")
if ! echo "$bz_existing" | jq -e 'type == "array"' >/dev/null 2>&1; then
  log "AVISO: Bazarr languages/profiles no devolvio una lista: no se tocan los perfiles ($bz_existing)"
else
  bz_merged=$(jq -cn --argjson e "$bz_existing" --argjson o "$BZ_OURS" '
    ($e | map(.name)) as $names
    | ([$e[].profileId] | max // 0) as $max
    | [$o[] | select(.name as $n | $names | index($n) | not)] as $missing
    | $e + [range(0; $missing | length) as $i | $missing[$i] + {profileId: ($max + 1 + $i)}]')
  if [ "$(echo "$bz_merged" | jq length)" -gt "$(echo "$bz_existing" | jq length)" ]; then
    BZ_CREATED=1
    # Idiomas activos = los que ya hubiera + en + es (si no, el perfil no
    # aparece en la interfaz). "languages-enabled" tambien reemplaza la lista.
    bz_langs=$(curl -s -H "X-API-KEY: $BAZARR_KEY" "http://bazarr:6767/api/system/languages" \
      | jq -r '([.[] | select(.enabled) | .code2] + ["en", "es"]) | unique | .[]')
    bz_args=()
    for l in $bz_langs; do bz_args+=(--data-urlencode "languages-enabled=$l"); done
    code=$(curl -s -o /tmp/resp -w "%{http_code}" -X POST "http://bazarr:6767/api/system/settings" \
      -H "X-API-KEY: $BAZARR_KEY" "${bz_args[@]}" --data-urlencode "languages-profiles=$bz_merged")
    case "$code" in
      2*) ;;
      *) log "AVISO: POST bazarr languages-profiles -> HTTP $code: $(cat /tmp/resp)" ;;
    esac
  fi
fi
BZ_DEFAULT=$(curl -s -H "X-API-KEY: $BAZARR_KEY" "http://bazarr:6767/api/system/languages/profiles" \
  | jq -r '[.[]? | select(.name == "ENGLISH + SPANISH")][0].profileId // empty')
[ -z "$BZ_DEFAULT" ] && log "AVISO: Bazarr sigue sin el perfil 'ENGLISH + SPANISH': no buscara subtitulos de lo nuevo"

# Sin esto, cualquier serie/pelicula que Bazarr detecte a partir de ahora
# (via Sonarr/Radarr) se queda con profileId null -- Bazarr no le busca
# subtitulos, sin ningun aviso visible (ver history/023, punto 9, caso
# real "Galavant"). Perfil "ENGLISH + SPANISH", el de arriba (por su id
# real, que no tiene por que ser 2).
# OJO, probado en vivo: estos booleanos van en minuscula ("true"/"false",
# convencion JS) -- a diferencia de "True"/"False" (estilo Python) que sí
# se usan dentro del JSON de languages_profiles de arriba. Mandar "True"
# aqui responde 406 "must is_type_of <class 'bool'> but it is True".
if [ -n "$BZ_DEFAULT" ]; then
log "Fijando perfil de idioma por defecto (ENGLISH + SPANISH, id $BZ_DEFAULT) para peliculas/series nuevas en Bazarr..."
code=$(curl -s -o /tmp/resp -w "%{http_code}" -X POST "http://bazarr:6767/api/system/settings" \
  -H "X-API-KEY: $BAZARR_KEY" \
  --data-urlencode 'settings-general-movie_default_enabled=true' \
  --data-urlencode "settings-general-movie_default_profile=$BZ_DEFAULT" \
  --data-urlencode 'settings-general-serie_default_enabled=true' \
  --data-urlencode "settings-general-serie_default_profile=$BZ_DEFAULT")
case "$code" in
  2*) ;;
  *) log "AVISO: POST bazarr default_profile -> HTTP $code: $(cat /tmp/resp)" ;;
esac

  # Lo que Bazarr ya conocia sin perfil se queda sin subtitulos (el
  # perfil por defecto solo vale para lo nuevo). Solo si los perfiles se
  # acaban de crear (instalacion nueva o rota como la del instalador hasta
  # 2026-10-16): donde ya existian, no se toca el perfil de nada.
  if [ "$BZ_CREATED" = 1 ]; then
    for kind in movies series; do
      if [ "$kind" = movies ]; then idf=radarrId; arg=radarrid; else idf=sonarrSeriesId; arg=seriesid; fi
      ids=$(curl -s -H "X-API-KEY: $BAZARR_KEY" "http://bazarr:6767/api/$kind" | jq -r --arg f "$idf" '.data[]? | select(.profileId == null) | .[$f]')
      [ -z "$ids" ] && continue
      bz_args=()
      for i in $ids; do bz_args+=(--data-urlencode "$arg=$i" --data-urlencode "profileid=$BZ_DEFAULT"); done
      code=$(curl -s -o /tmp/resp -w "%{http_code}" -X POST "http://bazarr:6767/api/$kind" -H "X-API-KEY: $BAZARR_KEY" "${bz_args[@]}")
      case "$code" in
        2*) log "Bazarr: perfil ENGLISH + SPANISH puesto a $(echo $ids | wc -w) $kind que no tenian." ;;
        *) log "AVISO: POST bazarr $kind profileid -> HTTP $code: $(cat /tmp/resp)" ;;
      esac
    done
  fi
fi

# Los defaults de Bazarr (85% series, 90% peliculas) rechazaban subtitulos
# validos; bajados a mano en la instancia real el 2026-08-31, codificados
# aqui para que sobrevivan a una reinstalacion. Son dos campos separados
# (minimum_score = series, minimum_score_movie = peliculas).
log "Fijando score minimo de subtitulos (series 70%, peliculas 80%) en Bazarr..."
code=$(curl -s -o /tmp/resp -w "%{http_code}" -X POST "http://bazarr:6767/api/system/settings" \
  -H "X-API-KEY: $BAZARR_KEY" \
  --data-urlencode 'settings-general-minimum_score=70' \
  --data-urlencode 'settings-general-minimum_score_movie=80')
case "$code" in
  2*) ;;
  *) log "AVISO: POST bazarr minimum_score -> HTTP $code: $(cat /tmp/resp)" ;;
esac

# Sincronizacion de subtitulos (ffsubsync) mas prudente. Sin umbral de
# puntuacion descuadro subtitulos que venian bien (2026-09-29, comprobado
# contra la pista incrustada: Silicon Valley 4x03 quedo +54 s tarde; al
# deshacer el desplazamiento, +-0,02 s). No se sincroniza lo que tiene
# puntuacion > 96%: es para esa version exacta del video (Bazarr solo
# sincroniza si score <= umbral; subtitles/sync.py). El tope de desfase
# se queria en 15 s (una correccion real de 12 s, Come and See, si hacia
# falta), pero Bazarr solo admite 60/120/300/600 (406 con otro valor, y
# entonces no aplica NINGUN campo de la peticion): 60 es el minimo.
log "Ajustando la sincronizacion de subtitulos de Bazarr (no a los de puntuacion > 96%)..."
code=$(curl -s -o /tmp/resp -w "%{http_code}" -X POST "http://bazarr:6767/api/system/settings" \
  -H "X-API-KEY: $BAZARR_KEY" \
  --data-urlencode 'settings-subsync-use_subsync=true' \
  --data-urlencode 'settings-subsync-max_offset_seconds=60' \
  --data-urlencode 'settings-subsync-use_subsync_threshold=true' \
  --data-urlencode 'settings-subsync-subsync_threshold=96' \
  --data-urlencode 'settings-subsync-use_subsync_movie_threshold=true' \
  --data-urlencode 'settings-subsync-subsync_movie_threshold=96')
case "$code" in
  2*) ;;
  *) log "AVISO: POST bazarr subsync -> HTTP $code: $(cat /tmp/resp)" ;;
esac

# Proveedores de subtitulos sin cuenta ni API key, como respaldo de
# opensubtitles.com (21 descargas/dia en la cuota gratuita, se agota con
# cualquier backlog -- 2026-09-29: "All providers are throttled"). Se
# SUMAN a los que ya haya (opensubtitlescom necesita credenciales y se
# configura a mano), nunca se quitan. Comprobados alcanzables desde el
# contenedor el 2026-09-29: gestdown y subtitulamostv (series, en/es),
# yifysubtitles (peliculas). 2026-10-19 (Bazarr 1.6.2), con opensubtitles
# agotado y 0 resultados para una pelicula de 2025: subtitlecat (peliculas
# y series, sin traducciones automaticas por defecto; fue el unico que la
# encontro) y subtis (solo espanol, peliculas). Descartados: podnapisi (ya
# no existe en 1.6.2), subf2m (522 de Cloudflare), subdivx (403),
# subx/subdl/subsource (API key).
# La lista se manda como campos repetidos (array_keys en app/config.py).
log "Anadiendo proveedores de subtitulos sin cuenta en Bazarr..."
providers=$(curl -s -H "X-API-KEY: $BAZARR_KEY" "http://bazarr:6767/api/system/settings" \
  | jq -r '(.general.enabled_providers // []) + ["gestdown","subtitulamostv","yifysubtitles","subtitlecat","subtis"] | unique | .[]')
provider_args=()
for p in $providers; do provider_args+=(--data-urlencode "settings-general-enabled_providers=$p"); done
code=$(curl -s -o /tmp/resp -w "%{http_code}" -X POST "http://bazarr:6767/api/system/settings" \
  -H "X-API-KEY: $BAZARR_KEY" "${provider_args[@]}")
case "$code" in
  2*) ;;
  *) log "AVISO: POST bazarr enabled_providers -> HTTP $code: $(cat /tmp/resp)" ;;
esac

# Conectar Bazarr a Radarr/Sonarr -- mismo endpoint settings ya usado arriba
# para los perfiles de idioma, campos confirmados contra una instalacion
# real via GET /api/system/settings (ya no es "demasiado variable para
# automatizar", como se penso originalmente -- ver
# development/history/027-simplificar-stack-e-instalacion.md).
log "Conectando Bazarr a Radarr..."
code=$(curl -s -o /tmp/resp -w "%{http_code}" -X POST "http://bazarr:6767/api/system/settings" \
  -H "X-API-KEY: $BAZARR_KEY" \
  --data-urlencode 'settings-general-use_radarr=true' \
  --data-urlencode 'settings-radarr-ip=radarr' \
  --data-urlencode 'settings-radarr-port=7878' \
  --data-urlencode "settings-radarr-apikey=${RADARR_KEY}" \
  --data-urlencode 'settings-radarr-ssl=false' \
  --data-urlencode 'settings-radarr-base_url=')
case "$code" in
  2*) ;;
  *) log "AVISO: POST bazarr radarr connection -> HTTP $code: $(cat /tmp/resp)" ;;
esac

log "Conectando Bazarr a Sonarr..."
code=$(curl -s -o /tmp/resp -w "%{http_code}" -X POST "http://bazarr:6767/api/system/settings" \
  -H "X-API-KEY: $BAZARR_KEY" \
  --data-urlencode 'settings-general-use_sonarr=true' \
  --data-urlencode 'settings-sonarr-ip=sonarr' \
  --data-urlencode 'settings-sonarr-port=8989' \
  --data-urlencode "settings-sonarr-apikey=${SONARR_KEY}" \
  --data-urlencode 'settings-sonarr-ssl=false' \
  --data-urlencode 'settings-sonarr-base_url=')
case "$code" in
  2*) ;;
  *) log "AVISO: POST bazarr sonarr connection -> HTTP $code: $(cat /tmp/resp)" ;;
esac

# ---------------------------------------------------------------------------
# 6d. (Opcional) Radarr/Sonarr -> Jellyfin Connect -- solo si JELLYFIN_API_KEY
#     esta en .env. No existe en el primer arranque (se genera a mano tras
#     el asistente inicial de Jellyfin, ver CONFIGURACION-MANUAL.md paso
#     2c) -- por eso esto es opcional y bootstrap hay que relanzarlo tras
#     rellenarla. Sin esto, Jellyfin depende solo de su monitorizacion en
#     tiempo real (poco fiable via WSL2/9p, ver history/013). Implementacion
#     y campos confirmados contra GET /api/v3/notification/schema real.
# ---------------------------------------------------------------------------
if [ -n "${JELLYFIN_API_KEY:-}" ]; then
  jellyfin_connect "http://radarr:7878/api/v3" "$RADARR_KEY" "$JELLYFIN_API_KEY" movie
  jellyfin_connect "http://sonarr:8989/api/v3" "$SONARR_KEY" "$JELLYFIN_API_KEY" series
fi

# ---------------------------------------------------------------------------
# 6e. Jellyfin: plugin Intro Skipper (spec 041). Clave de .env o, si no
#     esta, la que Seerr guarda de Jellyfin (asi funciona tambien tras el
#     instalador, que no la pone en .env). Si Jellyfin aun no responde, se
#     salta: firstrun.sh tambien lo instala.
# ---------------------------------------------------------------------------
JF_KEY="${JELLYFIN_API_KEY:-$(jq -r '.jellyfin.apiKey // empty' "$CONF/jellyseerr/settings.json" 2>/dev/null)}"
if [ -n "$JF_KEY" ]; then
  jellyfin_scan_interval "$JF_KEY"   # lo nuevo aparece en <= 15 min
  jellyfin_hwaccel "$JF_KEY" "${JELLYFIN_HWACCEL:-}"   # GPU (instalador)
  jellyfin_intro_skipper "$JF_KEY"
fi

# ---------------------------------------------------------------------------
# 7. Homer: config.yml con enlaces por IP LAN (localhost no sirve para
#    abrir el panel desde el movil/TV), mas el tema propio (logo, logos de
#    cada app, custom.css) que viaja dentro de esta imagen en
#    /assets/homer y se copia tal cual a ${CONFIG_ROOT}/homer -- ver
#    development/specs/019-rediseno-dashboard-homer.md.
#
#    Sin docker.sock ni root (ver development/history/026-sustituir-
#    homepage-por-homer.md). El estado en vivo lo pide el NAVEGADOR
#    directamente a cada app, y solo donde la app lo permite por CORS
#    (comprobado contra el stack real, 2026-09-25):
#      - Radarr/Sonarr/Prowlarr: tarjeta de Homer con su API key
#        (Access-Control-Allow-Origin: *). La key queda legible en
#        http://<IP>:3000/assets/config.yml para la LAN -- aceptado: esas
#        tres apps ya tienen el login desactivado en LAN.
#      - Jellyfin (/health), Bazarr (/) y disk-report (/health, envia
#        CORS a proposito): tipo "Ping", sin key.
#      - Seerr (antes Jellyseerr) y qBittorrent: sin cabeceras CORS -> sin indicador
#        (saldria siempre "offline"). La key de Jellyfin (admin, y
#        Jellyfin SI pide login en LAN) nunca se pone aqui.
#    footer: false quita el pie por defecto de Homer ("Created with
#    bulma, vuejs & font awesome").
# ---------------------------------------------------------------------------
LAN="${HOST_LAN_IP:-localhost}"

log "Generando homer/config.yml (enlaces sobre ${LAN})..."
mkdir -p "$CONF/homer"
cp -r /assets/homer/. "$CONF/homer/"
cat > "$CONF/homer/config.yml" <<EOF
# Generado por bootstrap -- los cambios a mano se pierden en el siguiente
# arranque. Editar la seccion 7 de bootstrap/bootstrap.sh y
# bootstrap/assets/homer/ en el repo.
title: "MediaCenter"
subtitle: "Ante el vicio de pedir, la virtud de no dar."
documentTitle: "MediaCenter"
logo: "assets/logo.svg"
footer: false
columns: "3"
connectivityCheck: true
updateIntervalMs: 30000

# links: false -> Homer no pinta la barra superior (Navbar lleva
# v-if="links"; omitirlo no basta, sus defaults ponen links: [] y un array
# vacio cuenta como verdadero),
# y con ella desaparecen el buscador y los interruptores de vista y de modo
# claro/oscuro. Efecto buscado: la vista queda siempre en columnas (vlayout
# arranca en true e ignora lo que el navegador tuviera guardado), pero el
# tema arranca en "light" -- por eso los dos modos llevan la misma paleta
# oscura.
links: false

defaults:
  layout: columns

stylesheet:
  - "assets/custom.css"

colors:
  light: &palette
    highlight-primary: "#7c6cff"
    highlight-secondary: "#9a8dff"
    highlight-hover: "#6a5aef"
    background: "#0d0e14"
    card-background: "#181a24"
    text: "#e6e6ef"
    text-header: "#ffffff"
    text-title: "#f4f4fb"
    text-subtitle: "#a3a3b8"
    card-shadow: rgba(0, 0, 0, 0.6)
    link: "#9a8dff"
    link-hover: "#ffffff"
  dark: *palette

# Tarjeta "Disco" (spec 028): el navegador la pide a disk-report cada minuto
# (Homer pinta "content" con innerHTML) con la barra de la pagina "Espacio
# en disco" y el boton de parar/continuar descargas. Ojo: si una peticion
# falla (disk-report caido), Homer deja de refrescarla hasta recargar.
message:
  url: "http://${LAN}:3001/api/homer"
  refreshInterval: 60000
  title: "Disco"
  content: "Cargando…"

services:
  - name: "Ver"
    icon: "fas fa-play"
    class: "featured"
    items:
      - name: "Jellyfin"
        logo: "assets/icons/jellyfin.svg"
        subtitle: "Ver películas y series"
        url: "http://${LAN}:8096"
        type: "Ping"
        endpoint: "http://${LAN}:8096/health"
      - name: "Seerr"
        logo: "assets/icons/seerr.svg"
        subtitle: "Pedir películas y series nuevas"
        url: "http://${LAN}:5055"

  - name: "Gestionar"
    icon: "fas fa-sliders-h"
    items:
      - name: "Radarr"
        logo: "assets/icons/radarr.svg"
        subtitle: "Películas"
        url: "http://${LAN}:7878"
        type: "Radarr"
        apikey: "${RADARR_KEY}"
      - name: "Sonarr"
        logo: "assets/icons/sonarr.svg"
        subtitle: "Series"
        url: "http://${LAN}:8989"
        type: "Sonarr"
        apikey: "${SONARR_KEY}"
      - name: "Bazarr"
        logo: "assets/icons/bazarr.svg"
        subtitle: "Subtítulos"
        url: "http://${LAN}:6767"
        type: "Ping"

  - name: "Sistema"
    icon: "fas fa-server"
    items:
      - name: "qBittorrent"
        logo: "assets/icons/qbittorrent.svg"
        subtitle: "Descargas en curso"
        url: "http://${LAN}:${QBT_PORT}"
      - name: "Prowlarr"
        logo: "assets/icons/prowlarr.svg"
        subtitle: "Fuentes de búsqueda"
        url: "http://${LAN}:9696"
        type: "Prowlarr"
        apikey: "${PROWLARR_KEY}"
      - name: "Espacio en disco"
        logo: "assets/icons/disk.svg"
        subtitle: "Qué ocupa el disco y qué sobra"
        url: "http://${LAN}:3001"
        type: "Ping"
        endpoint: "http://${LAN}:3001/health"
EOF

# ---------------------------------------------------------------------------
# 8. Recyclarr: perfiles de calidad y límites de tamaño (TRaSH Guides)
# ---------------------------------------------------------------------------
log "Generando configuracion de Recyclarr (perfiles de calidad + limites de tamano)..."
mkdir -p "$CONF/recyclarr"
cat > "$CONF/recyclarr/recyclarr.yml" <<EOF
# Generado automaticamente. Crea DOS perfiles de calidad en Radarr:
#
#   - "HD Bluray + WEB"    -> 1080p, tamano limitado (recomendado TRaSH)
#   - "Remux + WEB 2160p"  -> remux/4K sin recortar, tamano completo
#
# Ambos quedan disponibles en Radarr; TU eliges cual usar en cada pelicula.
#
# Sonarr usa el perfil "WEB-1080p" de TRaSH Guides. Si quieres anadir
# tambien un perfil remux/4K para series, dimelo.
#
# Los limites de tamano (quality_definition) son GLOBALES: se aplican a
# todos los perfiles, tambien a POPULAR/HD-1080p (los que de verdad se
# usan). Techo de 70 MB/min en 1080p en ambas apps (spec 022).

radarr:
  movies:
    base_url: http://radarr:7878
    api_key: ${RADARR_KEY}
    quality_definition:
      type: movie
      # Bluray-1080p traia un minimo de TRaSH de 50.8 MB/min -- 4 veces
      # el de WEBDL/WEBRip-1080p para la MISMA calidad real, solo por
      # como el release group etiqueto la fuente. Rechazaba releases
      # validos para peliculas largas (ver CHANGELOG.md, caso "Kingdom
      # of Heaven"). Quitado casi del todo (no se puede poner en 0).
      #
      # Techo de 70 MB/min en TODO 1080p (spec 022): las definiciones de
      # tamano son globales y afectan a todos los perfiles, incluido
      # POPULAR, que es el que se usa casi siempre (no puntua formatos).
      # Sin techo se bajaban versiones de 15-18GB (~120 MB/min, "Dune");
      # 70 deja pasar un 1080p normal (~8GB para 2h) y corta lo
      # desproporcionado. Mas holgado que el 32 que fallo en series (ver
      # development/history/004). Si el UNICO release de algo lo supera,
      # no se baja solo: sale rechazado por tamano en la busqueda
      # interactiva y se puede bajar a mano. "preferred" solo desempata.
      qualities:
        - name: Bluray-1080p
          min: 1
          preferred: 35
          max: 70
        - name: WEBDL-1080p
          preferred: 35
          max: 70
        - name: WEBRip-1080p
          preferred: 35
          max: 70
        - name: HDTV-1080p
          preferred: 35
          max: 70
        # Techo tambien en el resto (spec 027): 720p (40 MB/min, ~4.7GB
        # para 2h) y 4K/Remux (100, ~11.7GB para 2h). Los perfiles en uso
        # no admiten 4K ni Remux, pero asi, si alguien cambia a "Ultra-HD"
        # o elige a mano en la busqueda interactiva, lo desproporcionado
        # sale marcado como demasiado grande. Un Remux real (150-250
        # MB/min) queda fuera en la practica. Los minimos de TRaSH de
        # Bluray-2160p y Remux (100-190) se bajan: el maximo no puede ser
        # menor que el minimo. BR-DISK/Raw-HD no estan en la guia (no se
        # pueden tocar desde aqui); ningun perfil en uso los admite.
        - name: HDTV-720p
          preferred: 20
          max: 40
        - name: WEBDL-720p
          preferred: 20
          max: 40
        - name: WEBRip-720p
          preferred: 20
          max: 40
        - name: Bluray-720p
          # TRaSH trae 25.7 de minimo: mas que el preferido y, como en
          # Bluray-1080p, descarta justo los encodes ligeros.
          min: 10
          preferred: 20
          max: 40
        - name: HDTV-2160p
          min: 20
          preferred: 50
          max: 100
        - name: WEBDL-2160p
          min: 20
          preferred: 50
          max: 100
        - name: WEBRip-2160p
          min: 20
          preferred: 50
          max: 100
        - name: Bluray-2160p
          min: 20
          preferred: 50
          max: 100
        - name: Remux-1080p
          min: 1
          preferred: 50
          max: 100
        - name: Remux-2160p
          min: 1
          preferred: 50
          max: 100
    quality_profiles:
      - trash_id: d1d67249d3890e49bc12e275d989a7e9 # HD Bluray + WEB (1080p, por defecto)
        reset_unmatched_scores:
          enabled: true
      - trash_id: fd161a61e3ab826d3a22d53f935696dd # Remux + WEB 2160p (remux/4K, manual)
        reset_unmatched_scores:
          enabled: true

sonarr:
  shows:
    base_url: http://sonarr:8989
    api_key: ${SONARR_KEY}
    quality_definition:
      type: series
      # Techo de 70 MB/min en todo 1080p (~1.5GB por episodio de 22 min,
      # ~3GB de 44 min), spec 022. Antes no habia techo (se probo 32 y
      # rechazaba el unico release disponible, ver development/history/
      # 004): se bajaban temporadas de 50-66GB (~100-120 MB/min, "Malcolm
      # in the Middle", "Parks and Recreation"). "preferred" orienta hacia
      # ~616MB (28 MB/min) cuando hay varias opciones validas.
      #
      # Bluray-1080p traia de TRaSH un minimo de 50.4 MB/min: descartaba
      # justo los encodes ligeros y solo dejaba los enormes. Igualado a
      # WEBDL/WEBRip (15), como ya se hizo en Radarr.
      qualities:
        - name: WEBDL-1080p
          min: 15
          preferred: 28
          max: 70
        - name: WEBRip-1080p
          min: 15
          preferred: 28
          max: 70
        - name: Bluray-1080p
          min: 15
          preferred: 28
          max: 70
        - name: HDTV-1080p
          preferred: 28
          max: 70
        # Resto de calidades con techo (spec 027), mismo criterio que en
        # Radarr: 720p a 40 MB/min, 4K/Remux a 100.
        - name: HDTV-720p
          preferred: 15
          max: 40
        - name: WEBDL-720p
          preferred: 15
          max: 40
        - name: WEBRip-720p
          preferred: 15
          max: 40
        - name: Bluray-720p
          min: 10
          preferred: 15
          max: 40
        - name: HDTV-2160p
          min: 20
          preferred: 50
          max: 100
        - name: WEBDL-2160p
          min: 20
          preferred: 50
          max: 100
        - name: WEBRip-2160p
          min: 20
          preferred: 50
          max: 100
        - name: Bluray-2160p
          min: 20
          preferred: 50
          max: 100
        - name: Bluray-1080p Remux
          min: 1
          preferred: 50
          max: 100
        - name: Bluray-2160p Remux
          min: 1
          preferred: 50
          max: 100
    quality_profiles:
      - trash_id: 72dae194fc92bf828f32cde7744e51a1 # WEB-1080p (limites de tamano TRaSH)
        reset_unmatched_scores:
          enabled: true
EOF

log "========================================================================"
log "BOOTSTRAP COMPLETADO."
log "Prowlarr <-> Radarr/Sonarr conectados, categorias movies/tv creadas en"
log "qBittorrent, carpetas raiz configuradas, login desactivado en LAN para"
log "Radarr/Sonarr/Prowlarr, Bazarr conectado con perfiles de idioma, y"
log "Homer/Recyclarr generados."
log ""
log "Pendiente MANUAL:"
log "  1) Prowlarr (http://${LAN}:9696) -> anade tus indexadores/trackers"
log "  2) Jellyfin (http://${LAN}:8096) -> asistente inicial (usuario admin"
log "     y bibliotecas /data/media/movies y /data/media/tv). Para acceso"
log "     sin contrasena desde el movil/TV: crea ademas un usuario con"
log "     contrasena en blanco (ver README)."
log "  3) Seerr (http://${LAN}:5055) -> asistente inicial: inicia sesion"
log "     con el admin de Jellyfin, conecta Radarr y Sonarr (usa las mismas"
log "     API keys de arriba)."
log ""
log "  (Opcional) Radarr/Sonarr -> Jellyfin Connect (biblioteca se actualiza"
log "  sola al importar): anade JELLYFIN_API_KEY a .env con la key del paso 2"
log "  y vuelve a lanzar bootstrap (docker compose run --rm recyclarr sync)."
log "  Ver CONFIGURACION-MANUAL.md."
log ""
log "Credenciales qBittorrent -> usuario: ${QBT_USER} / password: ${QBT_PASS}"
log "CAMBIA esa contrasena desde la WebUI en tu primer login."
log "========================================================================"

exit 0
