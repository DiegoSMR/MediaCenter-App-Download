#!/bin/bash
# =============================================================================
# firstrun.sh — lo que antes eran pasos manuales tras instalar (spec 039):
# asistentes de Jellyfin y Seerr, Radarr/Sonarr -> Jellyfin, The Pirate Bay
# en Prowlarr y (si se dio) OpenSubtitles en Bazarr. Lo lanza el instalador
# una vez, despues de bootstrap:
#
#   docker compose --profile firstrun run --rm firstrun
#
# Idempotente: cada paso mira antes si ya esta hecho y, si lo esta, no toca
# nada (se puede relanzar tras un fallo). Sin MC_USER/MC_PASSWORD no hace
# nada. Termina con codigo 0 solo si todo quedo hecho; si no, 1 y el
# motivo en el log, para que el instalador lo diga.
# =============================================================================
set -uo pipefail
source /common.sh   # log(), wait_apikey(), jellyfin_connect()

CONF=/hostconfig
MC_USER="${MC_USER:-}"
MC_PASSWORD="${MC_PASSWORD:-}"
LAN="${HOST_LAN_IP:-localhost}"
JF=http://jellyfin:8096
SEERR=http://jellyseerr:5055
FAILED=0
# Idioma de los menus de las apps, elegido en el instalador (UI_LANG en .env,
# 2026-10-16; ingles por defecto). Solo se aplica aqui, una vez: si alguien
# lo cambia despues en una app, no se le deshace. Titulos y carteles van
# siempre en ingles (version original), elija lo que elija.
UI_LANG="${UI_LANG:-en}"
case "$UI_LANG" in
  es) JF_CULTURE=es; JF_WEB_LANG=es; ARR_LANG_ID=3 ;;
  *)  UI_LANG=en; JF_CULTURE=en-US; JF_WEB_LANG=en-us; ARR_LANG_ID=1 ;;
esac

if [ -z "$MC_USER" ] || [ -z "$MC_PASSWORD" ]; then
  log "Sin MC_USER/MC_PASSWORD: nada que hacer (solo lo usa el instalador)."
  exit 0
fi

fail() { log "ERROR: $*"; FAILED=1; }

# code_ok <codigo> <que> -- avisa si no es 2xx; devuelve 0 si lo es.
code_ok() {
  case "$1" in
    2*) return 0 ;;
    *) fail "$2 -> HTTP $1: $(head -c 400 /tmp/resp)"; return 1 ;;
  esac
}

until curl -sf -o /dev/null "$JF/health"; do log "esperando a Jellyfin..."; sleep 3; done
until curl -sf -o /dev/null "$SEERR/api/v1/status"; do log "esperando a Seerr..."; sleep 3; done
RADARR_KEY=$(wait_apikey "$CONF/radarr/config.xml" "Radarr")
SONARR_KEY=$(wait_apikey "$CONF/sonarr/config.xml" "Sonarr")
PROWLARR_KEY=$(wait_apikey "$CONF/prowlarr/config.xml" "Prowlarr")

# ---------------------------------------------------------------------------
# 1. Jellyfin: asistente inicial (sus /Startup/* no piden login mientras no
#    se haya completado), bibliotecas y API key.
# ---------------------------------------------------------------------------
AUTH='MediaBrowser Client="MediaCenter", Device="Instalador", DeviceId="mediacenter-firstrun", Version="1.0"'
jf() { # jf <metodo> <ruta> [json] -- deja el cuerpo en /tmp/resp, imprime el codigo
  curl -s -o /tmp/resp -w "%{http_code}" -X "$1" "$JF$2" -H "Authorization: $AUTH${TOKEN:+, Token=\"$TOKEN\"}" \
    -H "Content-Type: application/json" ${3:+--data-binary "$3"}
}
TOKEN=""
if [ "$(curl -s "$JF/System/Info/Public" | jq -r '.StartupWizardCompleted')" != "true" ]; then
  log "Jellyfin: asistente inicial (idioma, usuario administrador)..."
  # Menus en el idioma elegido (UI_LANG), pero titulos, sinopsis y carteles
  # en ingles (version original, decision del usuario 2026-10-16; con "es"
  # salian traducidos). Igual en las bibliotecas (lib_options) y en Seerr.
  code_ok "$(jf POST /Startup/Configuration "$(jq -cn --arg c "$JF_CULTURE" \
    '{UICulture:$c, MetadataCountryCode:"US", PreferredMetadataLanguage:"en"}')")" "Jellyfin /Startup/Configuration"
  code_ok "$(jf GET /Startup/User)" "Jellyfin GET /Startup/User"
  code_ok "$(jf POST /Startup/User "$(jq -n --arg u "$MC_USER" --arg p "$MC_PASSWORD" '{Name:$u, Password:$p}')")" "Jellyfin /Startup/User"
  code_ok "$(jf POST /Startup/RemoteAccess '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}')" "Jellyfin /Startup/RemoteAccess"
  code_ok "$(jf POST /Startup/Complete)" "Jellyfin /Startup/Complete"
else
  log "Jellyfin: el asistente ya estaba hecho."
fi

if code_ok "$(jf POST /Users/AuthenticateByName "$(jq -n --arg u "$MC_USER" --arg p "$MC_PASSWORD" '{Username:$u, Pw:$p}')")" "Jellyfin login"; then
  TOKEN=$(jq -r '.AccessToken' /tmp/resp)
  JF_USER_ID=$(jq -r '.User.Id' /tmp/resp)
  # La web de Jellyfin sigue el idioma del navegador salvo que el usuario
  # tenga uno guardado (sus preferencias "usersettings", cliente "emby",
  # clave "language"): se le guarda el elegido, valga para cualquier aparato.
  if jf GET "/DisplayPreferences/usersettings?userId=$JF_USER_ID&client=emby" >/dev/null \
     && prefs=$(jq -c --arg l "$JF_WEB_LANG" '.CustomPrefs.language = $l' /tmp/resp 2>/dev/null); then
    code_ok "$(jf POST "/DisplayPreferences/usersettings?userId=$JF_USER_ID&client=emby" "$prefs")" "Jellyfin idioma del usuario"
  fi
fi

# Radarr/Sonarr/Prowlarr: menus en el idioma elegido (Radarr/Sonarr usan el
# id de su lista de idiomas: 1 = ingles, 3 = espanol; Prowlarr, el codigo).
for a in "radarr 7878 v3" "sonarr 8989 v3" "prowlarr 9696 v1"; do
  set -- $a
  key=$(case $1 in radarr) echo "$RADARR_KEY" ;; sonarr) echo "$SONARR_KEY" ;; *) echo "$PROWLARR_KEY" ;; esac)
  ui=$(curl -s -H "X-Api-Key: $key" "http://$1:$2/api/$3/config/ui")
  if [ "$1" = prowlarr ]; then ui=$(echo "$ui" | jq -c --arg l "$UI_LANG" '.uiLanguage = $l')
  else ui=$(echo "$ui" | jq -c --argjson l "$ARR_LANG_ID" '.uiLanguage = $l'); fi
  code_ok "$(curl -s -o /tmp/resp -w "%{http_code}" -X PUT "http://$1:$2/api/$3/config/ui/$(echo "$ui" | jq -r .id)" \
    -H "X-Api-Key: $key" -H "Content-Type: application/json" -d "$ui")" "$1 idioma de los menus"
done

# Opciones de biblioteca = las que pone el asistente web de Jellyfin (copiadas
# de las bibliotecas del PC del usuario, 10.11). Por la API, lo que no se manda
# queda desactivado: sin EnableRealtimeMonitor Jellyfin IGNORA el aviso de
# Radarr/Sonarr (/Library/Media/Updated) y lo descargado no aparecia; sin
# TypeOptions no hay caratulas ni sinopsis (visto en la VM de prueba).
lib_options() { # lib_options <movies|tvshows> <ruta>
  jq -n --arg type "$1" --arg path "$2" '
    def fetch($m; $i): {MetadataFetchers:$m, MetadataFetcherOrder:$m, ImageFetchers:$i, ImageFetcherOrder:$i, ImageOptions:[]};
    {Enabled:true, EnablePhotos:true, EnableRealtimeMonitor:true, EnableLUFSScan:true,
     EnableChapterImageExtraction:false, ExtractChapterImagesDuringLibraryScan:false,
     EnableTrickplayImageExtraction:false, ExtractTrickplayImagesDuringLibraryScan:false,
     SaveLocalMetadata:false, EnableAutomaticSeriesGrouping:false, EnableEmbeddedTitles:false,
     EnableEmbeddedExtrasTitles:false, EnableEmbeddedEpisodeInfos:false, AutomaticRefreshIntervalDays:0,
     PreferredMetadataLanguage:"en", MetadataCountryCode:"US", SeasonZeroDisplayName:"Especiales",
     MetadataSavers:[], DisabledLocalMetadataReaders:[], LocalMetadataReaderOrder:["Nfo"],
     DisabledSubtitleFetchers:[], SubtitleFetcherOrder:[], SkipSubtitlesIfEmbeddedSubtitlesPresent:false,
     SkipSubtitlesIfAudioTrackMatches:false, SubtitleDownloadLanguages:[], RequirePerfectSubtitleMatch:true,
     SaveSubtitlesWithMedia:true, AutomaticallyAddToCollection:false, AllowEmbeddedSubtitles:"AllowAll",
     PathInfos:[{Path:$path}],
     TypeOptions:(if $type == "movies" then
       [{Type:"Movie"} + fetch(["TheMovieDb","The Open Movie Database"]; ["TheMovieDb","The Open Movie Database","Embedded Image Extractor","Screen Grabber"])]
     else
       [{Type:"Series"} + fetch(["TheMovieDb","The Open Movie Database"]; ["TheMovieDb"]),
        {Type:"Season"} + fetch(["TheMovieDb"]; ["TheMovieDb"]),
        {Type:"Episode"} + fetch(["TheMovieDb","The Open Movie Database"]; ["TheMovieDb","The Open Movie Database","Embedded Image Extractor","Screen Grabber"])]
     end)}'
}
if [ -n "$TOKEN" ]; then
  jf GET /Library/VirtualFolders >/dev/null
  cp /tmp/resp /tmp/libs
  for lib in "Películas|movies|/data/media/movies" "Series|tvshows|/data/media/tv"; do
    IFS='|' read -r name type path <<<"$lib"
    existing=$(jq -c --arg p "$path" '[.[] | select(.Locations | index($p))][0] // empty' /tmp/libs)
    if [ -n "$existing" ]; then
      # Creada antes sin estas opciones (version anterior de firstrun): se arregla.
      if [ "$(jq -r '.LibraryOptions.EnableRealtimeMonitor' <<<"$existing")" = "true" ]; then
        log "Jellyfin: la biblioteca de $path ya existe."
      else
        log "Jellyfin: activando la monitorizacion y los metadatos de la biblioteca de $path..."
        code_ok "$(jf POST /Library/VirtualFolders/LibraryOptions \
          "$(jq -n --arg id "$(jq -r '.ItemId' <<<"$existing")" --argjson o "$(lib_options "$type" "$path")" '{Id:$id, LibraryOptions:$o}')")" \
          "Jellyfin opciones de $name"
      fi
      continue
    fi
    log "Jellyfin: creando la biblioteca $name ($path)..."
    code_ok "$(jf POST "/Library/VirtualFolders?name=$(jq -rn --arg n "$name" '$n|@uri')&collectionType=$type&refreshLibrary=true" \
      "$(jq -n --argjson o "$(lib_options "$type" "$path")" '{LibraryOptions:$o}')")" \
      "Jellyfin biblioteca $name"
  done

  jf GET /Auth/Keys >/dev/null
  JELLYFIN_KEY=$(jq -r '[.Items[] | select(.AppName=="MediaCenter")][0].AccessToken // empty' /tmp/resp)
  if [ -z "$JELLYFIN_KEY" ]; then
    log "Jellyfin: creando la API key 'MediaCenter'..."
    code_ok "$(jf POST "/Auth/Keys?app=MediaCenter")" "Jellyfin /Auth/Keys"
    jf GET /Auth/Keys >/dev/null
    JELLYFIN_KEY=$(jq -r '[.Items[] | select(.AppName=="MediaCenter")][0].AccessToken // empty' /tmp/resp)
  fi
  if [ -n "$JELLYFIN_KEY" ]; then
    # Radarr/Sonarr avisan a Jellyfin de cada importacion (lo que en este PC
    # se hizo a mano con JELLYFIN_API_KEY en .env).
    jellyfin_connect "http://radarr:7878/api/v3" "$RADARR_KEY" "$JELLYFIN_KEY" movie
    jellyfin_connect "http://sonarr:8989/api/v3" "$SONARR_KEY" "$JELLYFIN_KEY" series
    jellyfin_scan_interval "$JELLYFIN_KEY"   # lo descargado aparece en <= 15 min
    jellyfin_hwaccel "$JELLYFIN_KEY" "${JELLYFIN_HWACCEL:-}"   # GPU NVIDIA (instalador)
    jellyfin_intro_skipper "$JELLYFIN_KEY"   # boton "Saltar intro" (spec 041)
  else
    fail "Jellyfin: no hay API key; Radarr/Sonarr no avisaran a Jellyfin"
  fi
else
  fail "Jellyfin: no se pudo iniciar sesion con el usuario del instalador"
fi

# ---------------------------------------------------------------------------
# 2. Seerr: el primer login con Jellyfin crea el administrador (si no hay
#    ningun usuario; si ya existe, solo inicia sesion). Despues, cada paso
#    por separado y solo si falta: bibliotecas, Radarr/Sonarr con "Mas
#    seeders", espanol, e "inicializado" (sin esto enseña el asistente) --
#    este ultimo solo si todo lo anterior salio bien, para que un fallo a
#    medias se pueda relanzar.
# ---------------------------------------------------------------------------
SEERR_COOKIE=/tmp/seerr_cookie
seerr() { # seerr <metodo> <ruta> [json]
  curl -s -o /tmp/resp -w "%{http_code}" -X "$1" "$SEERR/api/v1$2" -b "$SEERR_COOKIE" -c "$SEERR_COOKIE" \
    -H "Content-Type: application/json" ${3:+--data-binary "$3"}
}
FAILED_BEFORE_SEERR=$FAILED
# El servidor (hostname...) solo se manda la primera vez: con Jellyfin ya
# configurado, Seerr responde 500 "Jellyfin hostname already configured".
# mediaServerType 4 = NOT_CONFIGURED.
if [ "$(curl -s "$SEERR/api/v1/settings/public" | jq -r '.mediaServerType')" = "4" ]; then
  log "Seerr: primer inicio de sesion con Jellyfin (crea el administrador)..."
  login=$(jq -n --arg u "$MC_USER" --arg p "$MC_PASSWORD" \
    '{username:$u, password:$p, hostname:"jellyfin", port:8096, urlBase:"", useSsl:false, serverType:2,
      email:($u + "@mediacenter.local")}')
else
  log "Seerr: inicio de sesion con Jellyfin..."
  login=$(jq -n --arg u "$MC_USER" --arg p "$MC_PASSWORD" '{username:$u, password:$p}')
fi
if code_ok "$(seerr POST /auth/jellyfin "$login")" "Seerr /auth/jellyfin"; then
  # Seerr v3: POST .../library/sync trae las bibliotecas (conserva las ya
  # activadas) y cada una se activa con PUT .../library/{id}.
  if code_ok "$(seerr POST /settings/jellyfin/library/sync)" "Seerr sincronizar bibliotecas"; then
    for id in $(jq -r '.[] | select(.enabled != true) | .id' /tmp/resp); do
      log "Seerr: activando la biblioteca $id..."
      code_ok "$(seerr PUT "/settings/jellyfin/library/$id" '{"enabled":true}')" "Seerr activar biblioteca $id"
    done
  fi

  for app in radarr sonarr; do
    seerr GET "/settings/$app" >/dev/null
    if [ "$(jq 'length' /tmp/resp 2>/dev/null)" != "0" ]; then
      log "Seerr: $app ya estaba conectado."
      continue
    fi
    if [ "$app" = radarr ]; then port=7878; key=$RADARR_KEY; dir=/data/media/movies
    else port=8989; key=$SONARR_KEY; dir=/data/media/tv; fi
    profile=$(curl -s -H "X-Api-Key: $key" "http://$app:$port/api/v3/qualityprofile" \
      | jq -c '[.[] | select(.name=="Mas seeders")][0] // (.[0])')
    pid=$(jq -r '.id' <<<"$profile"); pname=$(jq -r '.name' <<<"$profile")
    log "Seerr: conectando $app (perfil '$pname')..."
    body=$(jq -n --arg app "$app" --argjson port "$port" --arg key "$key" --argjson pid "$pid" --arg pname "$pname" \
      --arg dir "$dir" --arg ext "http://$LAN:$port" \
      '{name:$app, hostname:$app, port:$port, apiKey:$key, useSsl:false, baseUrl:"",
        activeProfileId:$pid, activeProfileName:$pname, activeDirectory:$dir,
        is4k:false, isDefault:true, externalUrl:$ext, syncEnabled:false, preventSearch:false, tags:[]}
       + (if $app == "radarr" then {minimumAvailability:"released"}
          else {activeAnimeProfileId:$pid, activeAnimeProfileName:$pname, activeAnimeDirectory:$dir,
                seriesType:"standard", animeSeriesType:"anime", enableSeasonFolders:true, animeTags:[]} end)')
    code_ok "$(seerr POST "/settings/$app" "$body")" "Seerr conectar $app"
  done

  # Solo el idioma: el objeto entero lo rechaza (apiKey es de solo lectura).
  # Ingles (2026-10-16, decision del usuario): titulos y carteles en version
  # original, como prefiere el usuario. Con "es" salian traducidos ("En busca del arca
  # perdida"). Cada usuario puede cambiarlo en su perfil de Seerr.
  code_ok "$(seerr POST /settings/main '{"locale":"en"}')" "Seerr idioma"
  if [ "$(curl -s "$SEERR/api/v1/settings/public" | jq -r '.initialized')" = "true" ]; then
    log "Seerr: ya estaba inicializado."
  elif [ "$FAILED" = "$FAILED_BEFORE_SEERR" ]; then
    code_ok "$(seerr POST /settings/initialize)" "Seerr inicializar"
  else
    log "Seerr: NO se marca como inicializado (algo fallo arriba)."
  fi
fi

# ---------------------------------------------------------------------------
# 3. Prowlarr: The Pirate Bay (decision del usuario, spec 020/039). top100=1:
#    con el top 100 "reciente" (por defecto), Radarr no veia peliculas al
#    probarlo y nunca se sincronizaba (visto en la spec 020).
# ---------------------------------------------------------------------------
if curl -s -H "X-Api-Key: $PROWLARR_KEY" "http://prowlarr:9696/api/v1/indexer" \
    | jq -e 'any(.[]; .definitionName == "thepiratebay")' >/dev/null; then
  log "Prowlarr: The Pirate Bay ya estaba."
else
  log "Prowlarr: anadiendo The Pirate Bay..."
  body=$(curl -s -H "X-Api-Key: $PROWLARR_KEY" "http://prowlarr:9696/api/v1/indexer/schema" \
    | jq -c '[.[] | select(.definitionName == "thepiratebay")][0]
             | .enable = true | .appProfileId = 1 | .name = "The Pirate Bay"
             | (.fields[] | select(.name == "top100") | .value) = 1')
  code=$(curl -s -o /tmp/resp -w "%{http_code}" -X POST "http://prowlarr:9696/api/v1/indexer?forceSave=true" \
    -H "X-Api-Key: $PROWLARR_KEY" -H "Content-Type: application/json" --data-binary "$body")
  if code_ok "$code" "Prowlarr The Pirate Bay"; then
    curl -s -o /dev/null -X POST "http://prowlarr:9696/api/v1/command" -H "X-Api-Key: $PROWLARR_KEY" \
      -H "Content-Type: application/json" -d '{"name":"ApplicationIndexerSync"}'
  fi
fi

# ---------------------------------------------------------------------------
# 4. Bazarr: OpenSubtitles.com, solo si se dieron credenciales. Se SUMA a
#    los proveedores que ya hay (bootstrap pone los que no piden cuenta).
# ---------------------------------------------------------------------------
if [ -n "${OPENSUBTITLES_USER:-}" ] && [ -n "${OPENSUBTITLES_PASSWORD:-}" ]; then
  f="$CONF/bazarr/config/config.yaml"
  until [ -s "$f" ] && grep -qE '^\s*apikey:' "$f"; do sleep 3; done
  BAZARR_KEY=$(grep -m1 -E '^\s*apikey:' "$f" | sed -E 's/^\s*apikey:\s*//')
  log "Bazarr: anadiendo OpenSubtitles.com..."
  args=()
  for p in $(curl -s -H "X-API-KEY: $BAZARR_KEY" "http://bazarr:6767/api/system/settings" \
      | jq -r '(.general.enabled_providers // []) + ["opensubtitlescom"] | unique | .[]'); do
    args+=(--data-urlencode "settings-general-enabled_providers=$p")
  done
  code=$(curl -s -o /tmp/resp -w "%{http_code}" -X POST "http://bazarr:6767/api/system/settings" -H "X-API-KEY: $BAZARR_KEY" \
    --data-urlencode "settings-opensubtitlescom-username=$OPENSUBTITLES_USER" \
    --data-urlencode "settings-opensubtitlescom-password=$OPENSUBTITLES_PASSWORD" "${args[@]}")
  code_ok "$code" "Bazarr OpenSubtitles"
fi

if [ "$FAILED" = 0 ]; then
  log "Todo configurado."
else
  log "Terminado CON ERRORES (ver arriba). Se puede relanzar: no repite lo que ya esta hecho."
fi
exit "$FAILED"
