# common.sh — funciones compartidas, usadas por bootstrap.sh. Se importa
# con "source", no se ejecuta solo.

log() { echo "[$(basename "$0" .sh)] $*" >&2; }   # a stderr: nunca debe colarse en un $(...)

jellyfin_connect() {
  # jellyfin_connect <base_api_url> <apikey> <jellyfin_key> <movie|series>
  # Radarr/Sonarr -> Jellyfin "Connect": avisa a Jellyfin de cada
  # importacion (su monitorizacion en tiempo real no es fiable via
  # WSL2/9p, ver history/013). No duplica si ya existe. Campos confirmados
  # contra GET /api/v3/notification/schema real. La usan bootstrap.sh (con
  # JELLYFIN_API_KEY de .env) y firstrun.sh (con la key que crea el).
  local base="$1" key="$2" jkey="$3" kind="$4" code body
  if curl -s -H "X-Api-Key: $key" "$base/notification" \
      | jq -e 'any(.[]; .implementation=="MediaBrowser")' >/dev/null; then
    log "Connect a Jellyfin ya existe en $base, no se duplica."
    return
  fi
  log "Conectando $base a Jellyfin (Connect)..."
  body=$(jq -n --arg k "$jkey" --arg kind "$kind" '
    {onGrab:false, onDownload:true, onUpgrade:true, onRename:true, onHealthIssue:false, onApplicationUpdate:false,
     name:"Jellyfin", implementation:"MediaBrowser", configContract:"MediaBrowserSettings",
     fields:[{name:"host",value:"jellyfin"},{name:"port",value:8096},{name:"useSsl",value:false},
             {name:"apiKey",value:$k},{name:"updateLibrary",value:true}]}
    + (if $kind == "movie"
       then {onMovieDelete:true, onMovieFileDelete:true, onMovieFileDeleteForUpgrade:true}
       else {onSeriesDelete:true, onEpisodeFileDelete:true, onEpisodeFileDeleteForUpgrade:true} end)')
  code=$(curl -s -o /tmp/resp -w "%{http_code}" -X POST "$base/notification" \
    -H "X-Api-Key: $key" -H "Content-Type: application/json" --data-binary "$body")
  case "$code" in
    2*) ;;
    *) log "AVISO: POST $base/notification -> HTTP $code: $(cat /tmp/resp)" ;;
  esac
}

jellyfin_intro_skipper() {
  # jellyfin_intro_skipper <jellyfin_key> -- plugin Intro Skipper (spec 041):
  # detecta las intros por el audio y Jellyfin enseña "Saltar intro". Añade
  # su repositorio (sin quitar ninguno), lo instala y reinicia Jellyfin una
  # vez para cargarlo. Si ya esta, no hace nada. Nunca falla: sin el plugin
  # Jellyfin funciona igual. La usan bootstrap.sh y firstrun.sh.
  local jkey="$1" jf=http://jellyfin:8096 name="Intro Skipper" i code
  local repo="https://intro-skipper.org/manifest.json"
  # Jellyfin 12.2 solo acepta la clave en "Authorization: MediaBrowser
  # Token=..." (X-Emby-Token, X-MediaBrowser-Token y ?api_key= dan 401,
  # comprobado 2026-10-16); esta forma vale tambien en versiones antiguas.
  local h="Authorization: MediaBrowser Token=\"$jkey\""
  if ! curl -sf -m 5 -o /dev/null "$jf/health"; then
    log "Jellyfin no responde: Intro Skipper se instalara la proxima vez."
    return 0
  fi
  if curl -s -H "$h" "$jf/Plugins" | jq -e --arg n "$name" 'any(.[]; .Name == $n)' >/dev/null; then
    log "Intro Skipper ya esta instalado en Jellyfin."
    return 0
  fi
  if ! curl -s -H "$h" "$jf/Repositories" | jq -e --arg u "$repo" 'any(.[]; .Url == $u)' >/dev/null; then
    log "Jellyfin: anadiendo el repositorio de Intro Skipper..."
    code=$(curl -s -H "$h" "$jf/Repositories" \
      | jq -c --arg u "$repo" '. + [{Name: "Intro Skipper", Url: $u, Enabled: true}]' \
      | curl -s -o /tmp/resp -w "%{http_code}" -X POST "$jf/Repositories" -H "$h" \
          -H "Content-Type: application/json" --data-binary @-)
    case "$code" in 2*) ;; *) log "AVISO: Jellyfin repositorio Intro Skipper -> HTTP $code: $(cat /tmp/resp)"; return 0 ;; esac
  fi
  log "Jellyfin: instalando Intro Skipper..."
  code=$(curl -s -o /tmp/resp -w "%{http_code}" -X POST -H "$h" \
    "$jf/Packages/Installed/Intro%20Skipper?repositoryUrl=$(jq -rn --arg u "$repo" '$u|@uri')")
  case "$code" in 2*) ;; *) log "AVISO: Jellyfin instalar Intro Skipper -> HTTP $code: $(cat /tmp/resp)"; return 0 ;; esac
  # La instalacion va en segundo plano: el plugin aparece en /Plugins
  # (pendiente de reinicio) cuando ha terminado de descargarse.
  local ok=""
  for i in $(seq 1 60); do
    curl -s -H "$h" "$jf/Plugins" | jq -e --arg n "$name" 'any(.[]; .Name == $n)' >/dev/null && { ok=1; break; }
    sleep 2
  done
  if [ -z "$ok" ]; then log "AVISO: Intro Skipper no aparece instalado tras 2 min."; return 0; fi
  log "Jellyfin: reiniciando para cargar Intro Skipper..."
  curl -s -o /dev/null -X POST -H "$h" "$jf/System/Restart"
  sleep 10
  # Mientras arranca, un servidor provisional ya responde /health: hay que
  # esperar a que la API de verdad conteste (comprobado en vivo).
  for i in $(seq 1 60); do curl -sf -m 5 -o /dev/null -H "$h" "$jf/Plugins" && break; sleep 3; done
  log "Intro Skipper: $(curl -s -H "$h" "$jf/Plugins" | jq -r --arg n "$name" '[.[] | select(.Name == $n)][0] | "\(.Version) \(.Status)"')"
  # Primer analisis ya, sin esperar a su tarea diaria.
  i=$(curl -s -H "$h" "$jf/ScheduledTasks" | jq -r '[.[] | select(.Key == "IntroSkipperDetectSegmentsTask")][0].Id // empty')
  if [ -n "$i" ]; then
    curl -s -o /dev/null -X POST -H "$h" "$jf/ScheduledTasks/Running/$i"
    log "Intro Skipper: analizando la biblioteca (puede tardar un rato)."
  fi
}

prowlarr_extra_indexers() {
  # prowlarr_extra_indexers <prowlarr_key> -- mas indexadores aparte de The
  # Pirate Bay (spec 052): con uno solo, si se caia o habia futbol no se
  # descargaba nada. Probado desde Digi (2026-10-17): YTS, Knaben y Nyaa
  # van solos; EZTV y 1337x necesitan FlareSolverr (proteccion de
  # Cloudflare), y 1337x ademas el DNS 1.1.1.1 de Prowlarr (la operadora
  # devuelve 127.0.0.1). Solo UNA vez por instalacion (marca en la config de
  # Prowlarr): si alguien quita uno despues, no se vuelve a poner. Nunca
  # quita ninguno. Nyaa es de anime, pero es el unico con IP propia: sigue
  # funcionando con los bloqueos de LaLiga.
  local key="$1" p=http://prowlarr:9696/api/v1 mark="$CONF/prowlarr/.mediacenter-indexadores-052"
  local h="X-Api-Key: $key" tag existing schema code n
  [ -f "$mark" ] && return 0
  existing=$(curl -s -H "$h" "$p/indexer")
  echo "$existing" | jq -e 'type == "array"' >/dev/null 2>&1 || { log "AVISO: Prowlarr no responde: indexadores extra la proxima vez."; return 0; }
  # Etiqueta + proxy FlareSolverr: solo lo usan los indexadores con esa etiqueta.
  tag=$(curl -s -H "$h" "$p/tag" | jq -r '[.[] | select(.label == "flaresolverr")][0].id // empty')
  [ -z "$tag" ] && tag=$(curl -s -X POST -H "$h" -H "Content-Type: application/json" "$p/tag" -d '{"label":"flaresolverr"}' | jq -r '.id // empty')
  if [ -n "$tag" ] && ! curl -s -H "$h" "$p/indexerProxy" | jq -e 'any(.[]; .implementation == "FlareSolverr")' >/dev/null; then
    code=$(curl -s -o /tmp/resp -w "%{http_code}" -X POST -H "$h" -H "Content-Type: application/json" "$p/indexerProxy?forceSave=true" \
      -d "$(jq -cn --argjson t "$tag" '{name:"FlareSolverr", implementation:"FlareSolverr", configContract:"FlareSolverrSettings",
            fields:[{name:"host", value:"http://flaresolverr:8191/"}, {name:"requestTimeout", value:60}], tags:[$t]}')")
    case "$code" in 2*) log "Prowlarr: proxy FlareSolverr anadido." ;; *) log "AVISO: Prowlarr proxy FlareSolverr -> HTTP $code: $(cat /tmp/resp)" ;; esac
  fi
  schema=$(curl -s -H "$h" "$p/indexer/schema")
  # definicion | nombre | prioridad (menor = antes) | necesita FlareSolverr
  for row in "Knaben|Knaben|25|0" "yts|YTS|30|0" "eztv|EZTV|30|1" "1337x|1337x|35|1" "nyaasi|Nyaa|40|0"; do
    IFS='|' read -r def name prio cf <<<"$row"
    if echo "$existing" | jq -e --arg d "$def" 'any(.[]; .definitionName == $d)' >/dev/null; then continue; fi
    body=$(echo "$schema" | jq -c --arg d "$def" --arg n "$name" --argjson pr "$prio" --argjson cf "$cf" --arg t "${tag:-0}" '
      [.[] | select(.definitionName == $d)][0] // empty
      | .enable = true | .appProfileId = 1 | .name = $n | .priority = $pr
      | .tags = (if $cf == 1 and ($t | tonumber) > 0 then [$t | tonumber] else [] end)')
    [ -z "$body" ] && { log "AVISO: Prowlarr no tiene la definicion '$def'."; continue; }
    code=$(curl -s -o /tmp/resp -w "%{http_code}" -X POST -H "$h" -H "Content-Type: application/json" "$p/indexer?forceSave=true" --data-binary "$body")
    case "$code" in 2*) log "Prowlarr: indexador $name anadido." ;; *) log "AVISO: Prowlarr indexador $name -> HTTP $code: $(head -c 300 /tmp/resp)" ;; esac
  done
  curl -s -o /dev/null -X POST -H "$h" -H "Content-Type: application/json" "$p/command" -d '{"name":"ApplicationIndexerSync"}'
  date -u +%FT%TZ > "$mark" 2>/dev/null || true
}

jellyfin_hwaccel() {
  # jellyfin_hwaccel <jellyfin_key> <tipo> -- aceleracion por hardware al
  # convertir video (JELLYFIN_HWACCEL en .env; "nvenc" lo pone el
  # instalador si hay GPU NVIDIA). Sin esto Jellyfin la dejaba en "none" y
  # convertia con el procesador aunque el contenedor viera la GPU
  # (2026-10-16, RTX 4070: h264/hevc_nvenc y decodificacion cuda probados
  # con el ffmpeg de Jellyfin). Solo si sigue en "none": nunca pisa lo que
  # el usuario haya elegido a mano. AV1 no: solo lo decodifican RTX 30+.
  local jkey="$1" type="$2" jf=http://jellyfin:8096 cur code
  [ -z "$type" ] && return 0
  local h="Authorization: MediaBrowser Token=\"$jkey\""
  cur=$(curl -s -m 10 -H "$h" "$jf/System/Configuration/encoding")
  if ! echo "$cur" | jq -e '.HardwareAccelerationType' >/dev/null 2>&1; then
    log "AVISO: Jellyfin no devuelve su configuracion de video: aceleracion $type no aplicada."; return 0
  fi
  if [ "$(echo "$cur" | jq -r '.HardwareAccelerationType')" != "none" ]; then
    log "Jellyfin: aceleracion de video ya configurada ($(echo "$cur" | jq -r '.HardwareAccelerationType')), no se toca."; return 0
  fi
  code=$(echo "$cur" | jq --arg t "$type" '.HardwareAccelerationType = $t | .EnableHardwareEncoding = true
      | .HardwareDecodingCodecs = ["h264","hevc","mpeg2video","vc1","vp8","vp9"]
      | .EnableDecodingColorDepth10Hevc = true | .EnableDecodingColorDepth10Vp9 = true' \
    | curl -s -o /tmp/resp -w "%{http_code}" -X POST "$jf/System/Configuration/encoding" -H "$h" \
        -H "Content-Type: application/json" --data-binary @-)
  case "$code" in
    2*) log "Jellyfin: aceleracion de video por hardware ($type) activada." ;;
    *) log "AVISO: Jellyfin aceleracion $type -> HTTP $code: $(cat /tmp/resp)" ;;
  esac
}

jellyfin_scan_interval() {
  # jellyfin_scan_interval <jellyfin_key> -- "Escanear biblioteca" cada 15
  # min (por defecto, cada 12 h). Sin esto lo descargado no aparecia en
  # Jellyfin hasta escanear a mano (2026-10-16): el aviso de Radarr/Sonarr
  # (POST /Library/Media/Updated) responde 204 pero no anade nada nuevo, y
  # la monitorizacion en tiempo real no ve cambios a traves del bind mount
  # de Docker Desktop. Escanear sin cambios es barato. Nunca falla.
  local jkey="$1" jf=http://jellyfin:8096 id code
  local h="Authorization: MediaBrowser Token=\"$jkey\""
  local ticks=$((15 * 60 * 10000000))
  id=$(curl -s -m 10 -H "$h" "$jf/ScheduledTasks" | jq -r '[.[]? | select(.Key == "RefreshLibrary")][0].Id // empty' 2>/dev/null)
  if [ -z "$id" ]; then log "AVISO: Jellyfin no responde o sin tarea RefreshLibrary: escaneo cada 15 min no configurado."; return 0; fi
  code=$(curl -s -o /tmp/resp -w "%{http_code}" -X POST "$jf/ScheduledTasks/$id/Triggers" -H "$h" \
    -H "Content-Type: application/json" -d "[{\"Type\":\"IntervalTrigger\",\"IntervalTicks\":$ticks}]")
  case "$code" in
    2*) log "Jellyfin: escaneo de la biblioteca cada 15 min." ;;
    *) log "AVISO: Jellyfin triggers RefreshLibrary -> HTTP $code: $(cat /tmp/resp)" ;;
  esac
}

wait_apikey() {
  local file="$1" name="$2"
  log "esperando config.xml de $name ..."
  until [ -s "$file" ] && grep -q "<ApiKey>" "$file"; do
    sleep 3
  done
  grep -oE '<ApiKey>[^<]+' "$file" | cut -d'>' -f2
}
