"""Comprobacion de la instalacion (spec 049).

Mira el RESULTADO en cada app, no el codigo HTTP de quien la configuro: el
2026-10-16 una instalacion nueva acabo "bien" con Bazarr sin perfiles,
Jellyfin rechazando la clave y Radarr/Sonarr pidiendo login, porque cada
ajuste habia devuelto 200 sin aplicarse. Solo lee; no cambia nada.

Cada comprobacion: ok / aviso / fallo, con detalle y que hacer.
- Suelto:  python3 /app/verify.py [--json]   (sale con 1 si hay fallos)
- Lo usan el instalador (via disk-clean) y disk-report (cada dia y con un
  boton). Solo biblioteca estandar, como el resto de disk-report.
"""
import http.cookiejar
import json
import os
import re
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

CONFIG = os.environ.get("VERIFY_CONFIG", "/config")
QBT_URL = os.environ.get("QBT_URL", "http://qbittorrent:8080")
QBT_USER = os.environ.get("QBT_USER", "admin")
QBT_PASS = os.environ.get("QBT_PASS", "adminadmin")
ARR_LOGIN = os.environ.get("ARR_LOGIN", "0")
JELLYFIN_HWACCEL = os.environ.get("JELLYFIN_HWACCEL", "")
# Lo recien importado tarda hasta 15 min en salir en Jellyfin y una serie
# nueva hasta 1 h en llegar a Bazarr: margen para no dar falsos avisos.
JELLYFIN_GRACE_S = 3600
BAZARR_GRACE_S = 2 * 3600
MAX_1080P_MB_MIN = 70

# Bloqueos de LaLiga (spec 050): en dias de partido las operadoras bloquean
# IPs de Cloudflare, y la API de The Pirate Bay esta detras. Lista de
# hayahora.futbol (mediciones de su autor, no oficial): vacia sin bloqueos.
# Variables solo para probar sin esperar a un partido.
FOOTBALL_LIST_URL = os.environ.get("FOOTBALL_LIST_URL", "https://hayahora.futbol/estado/blocked-any.txt")
TPB_TEST_URL = os.environ.get("TPB_TEST_URL", "https://apibay.org/q.php?q=test")
FOOTBALL_MSG = "⚽ Hay fútbol: LaLiga está bloqueando IPs y The Pirate Bay no responde. Gracias. FUCK TEBAS"

FIX_BOOTSTRAP = ("Vuelve a aplicar la configuración automática: ejecuta scripts\\start.ps1 "
                 "en la carpeta de MediaCenter (tarda unos minutos).")
APPS = {"radarr": ("http://radarr:7878", "v3"), "sonarr": ("http://sonarr:8989", "v3"),
        "prowlarr": ("http://prowlarr:9696", "v1")}
NAMES = {"radarr": "Radarr", "sonarr": "Sonarr", "prowlarr": "Prowlarr"}


class Checks:
    def __init__(self):
        self.items = []

    def add(self, app, name, level, detail="", fix=""):
        self.items.append({"app": app, "name": name, "level": level, "detail": detail,
                           "fix": fix if level != "ok" else ""})

    def ok(self, app, name, detail=""):
        self.add(app, name, "ok", detail)

    def aviso(self, app, name, detail, fix=FIX_BOOTSTRAP):
        self.add(app, name, "aviso", detail, fix)

    def fallo(self, app, name, detail, fix=FIX_BOOTSTRAP):
        self.add(app, name, "fallo", detail, fix)


# ---------------------------------------------------------------------------
# Acceso a las apps
# ---------------------------------------------------------------------------
def read(path):
    try:
        with open(os.path.join(CONFIG, path), encoding="utf-8") as f:
            return f.read()
    except OSError:
        return None


def arr_key(app):
    m = re.search(r"<ApiKey>(.*?)</ApiKey>", read(f"{app}/config.xml") or "")
    return m.group(1) if m else None


def seerr_settings():
    try:
        return json.loads(read("jellyseerr/settings.json") or "")
    except ValueError:
        return {}


def bazarr_key():
    # config.yaml: "auth:" y debajo "  apikey: ..." (sin PyYAML: solo stdlib)
    m = re.search(r"^auth:\s*\n(?:[ \t]+.*\n)*?[ \t]+apikey:\s*['\"]?([0-9a-f]+)", read("bazarr/config/config.yaml") or "", re.M)
    return m.group(1) if m else None


def get(url, headers=None, timeout=20, opener=None):
    req = urllib.request.Request(url, headers=headers or {})
    r = (opener.open if opener else urllib.request.urlopen)(req, timeout=timeout)
    body = r.read()
    return json.loads(body) if body.strip() else None


def arr(app, path):
    base, ver = APPS[app]
    return get(f"{base}/api/{ver}/{path}", {"X-Api-Key": arr_key(app) or ""})


def err(e):
    if isinstance(e, urllib.error.HTTPError):
        return f"HTTP {e.code}"
    if isinstance(e, urllib.error.URLError):
        return f"no responde ({e.reason})"
    return f"{type(e).__name__}: {e}"


def older_than(iso, seconds):
    """True si la fecha ISO (de Radarr/Sonarr) es de hace mas de `seconds`."""
    if not iso:
        return False
    try:
        t = time.mktime(time.strptime(iso[:19], "%Y-%m-%dT%H:%M:%S")) - time.timezone
    except ValueError:
        return False
    return time.time() - t > seconds


def few(names, n=5):
    names = sorted(names)
    return ", ".join(names[:n]) + (f" y {len(names) - n} más" if len(names) > n else "")


# ---------------------------------------------------------------------------
# Comprobaciones
# ---------------------------------------------------------------------------
def check_arr(c, app):
    name = NAMES[app]
    if not arr_key(app):
        c.fallo(name, "Configuración", f"No encuentro la clave de {name} (config.xml).")
        return False
    try:
        health = arr(app, "health") or []
    except Exception as e:  # noqa: BLE001
        c.fallo(name, "Responde", f"{name} {err(e)}.", f"Comprueba que {name} está arrancado (scripts\\status.ps1).")
        return False
    bad = [h for h in health if h.get("type") == "error"]
    warn = [h for h in health if h.get("type") == "warning"]
    if bad:
        c.fallo(name, "Su propia comprobación", "; ".join(h.get("message", "") for h in bad),
                f"Abre {name} > System > Status: explica cada problema.")
    elif warn:
        c.aviso(name, "Su propia comprobación", "; ".join(h.get("message", "") for h in warn),
                f"Abre {name} > System > Status: explica cada aviso.")
    else:
        c.ok(name, "Su propia comprobación")

    host = arr(app, "config/host") or {}
    want = "forms" if ARR_LOGIN == "1" else "external"
    method = (host.get("authenticationMethod") or "").lower()
    if method != want:
        c.fallo(name, "Login", f"Debería ser '{want}' (ARR_LOGIN={ARR_LOGIN}) y es '{method or '?'}'"
                + (": pide usuario y contraseña" if want == "external" else ": no pide contraseña") + ".")
    else:
        c.ok(name, "Login", "con contraseña" if want == "forms" else "sin contraseña")
    if (host.get("logLevel") or "").lower() not in ("info", "warn", "error"):
        c.aviso(name, "Nivel de log", f"Está en '{host.get('logLevel')}': la búsqueda interactiva va muy lenta.")
    return True


def check_arr_library(c, app, qbt_cats):
    name = NAMES[app]
    for rf in arr(app, "rootfolder") or [{"path": "(ninguna)", "accessible": False}]:
        if rf.get("accessible"):
            c.ok(name, "Carpeta de la biblioteca", rf.get("path"))
        else:
            c.fallo(name, "Carpeta de la biblioteca", f"{rf.get('path')} no es accesible.")

    clients = [d for d in arr(app, "downloadclient") or [] if d.get("implementation") == "QBittorrent"]
    if not clients:
        c.fallo(name, "Cliente de descargas", "No tiene qBittorrent como cliente de descargas.")
    for d in clients:
        fields = {f.get("name"): f.get("value") for f in d.get("fields", [])}
        cat = fields.get("movieCategory") or fields.get("tvCategory")
        problems = []
        if not d.get("enable"):
            problems.append("está desactivado")
        if not d.get("removeCompletedDownloads"):
            problems.append("no borra lo ya compartido (Remove Completed)")
        if qbt_cats is not None and cat and not (qbt_cats.get(cat) or {}).get("savePath"):
            problems.append(f"la categoría '{cat}' no tiene carpeta en qBittorrent: lo descargado cae suelto en torrents\\")
        if problems:
            c.aviso(name, "Cliente de descargas", "qBittorrent: " + "; ".join(problems) + ".")
        else:
            c.ok(name, "Cliente de descargas", f"qBittorrent, categoría '{cat}'")

    if not [i for i in arr(app, "indexer") or [] if i.get("enableRss") or i.get("enableAutomaticSearch")]:
        c.fallo(name, "Buscadores", "No tiene ningún buscador: no puede descargar nada.",
                "Comprueba en Prowlarr que hay al menos un indexador (The Pirate Bay) y vuelve a aplicar la configuración: "
                + FIX_BOOTSTRAP)
    else:
        c.ok(name, "Buscadores")

    if not any(p.get("name") == "Mas seeders" for p in arr(app, "qualityprofile") or []):
        c.aviso(name, "Perfil 'Mas seeders'", "No existe.")
    defs = {d.get("quality", {}).get("name"): d for d in arr(app, "qualitydefinition") or []}
    mx = (defs.get("WEBDL-1080p") or {}).get("maxSize")
    if mx is None or mx > MAX_1080P_MB_MIN:
        c.aviso(name, "Límite de tamaño", f"1080p sin límite de {MAX_1080P_MB_MIN} MB/min (ahora: {mx}).",
                "Aplica los perfiles de calidad: docker compose run --rm recyclarr sync")
    else:
        c.ok(name, "Límite de tamaño", f"1080p hasta {mx:g} MB/min")


def football_status():
    """{"blocking": hay IPs bloqueadas ahora, "tpb_ok": The Pirate Bay
    responde, "tpb_blocked": su IP esta en la lista, "active": hay que
    mostrar el aviso}. Si la lista no se puede leer, blocking=None y nunca
    se avisa: mejor callar que decir "hay futbol" sin saberlo."""
    r = {"checked_at": int(time.time()), "blocking": None, "blocked_ips": 0, "tpb_ok": None, "tpb_blocked": False,
         "active": False, "message": FOOTBALL_MSG}
    try:
        txt = urllib.request.urlopen(FOOTBALL_LIST_URL, timeout=15).read().decode(errors="replace")
        ips = {ln.strip() for ln in txt.splitlines() if re.fullmatch(r"[0-9a-fA-F.:/]+", ln.strip())}
        r["blocking"], r["blocked_ips"] = bool(ips), len(ips)
    except Exception:  # noqa: BLE001
        ips = set()
    try:
        host = urllib.parse.urlparse(TPB_TEST_URL).hostname
        r["tpb_blocked"] = any(a[4][0] in ips for a in socket.getaddrinfo(host, 443))
    except Exception:  # noqa: BLE001
        pass
    try:
        urllib.request.urlopen(urllib.request.Request(TPB_TEST_URL, headers={"User-Agent": "Mozilla/5.0"}), timeout=15).read(1)
        r["tpb_ok"] = True
    except Exception:  # noqa: BLE001
        r["tpb_ok"] = False
    r["active"] = bool(r["blocking"]) and (r["tpb_ok"] is False or r["tpb_blocked"])
    return r


def check_prowlarr(c):
    idx = [i for i in arr("prowlarr", "indexer") or [] if i.get("enable")]
    if idx:
        c.ok("Prowlarr", "Indexadores", ", ".join(i.get("name", "?") for i in idx))
    else:
        c.fallo("Prowlarr", "Indexadores", "No hay ningún indexador activo: no se puede buscar nada.",
                "Abre Prowlarr > Indexers y añade The Pirate Bay.")
    # Cuantos responden (spec 052): Prowlarr aparta un rato los que fallan
    # (indexerstatus con disabledTill en el futuro).
    f = football_status()
    if idx:
        now = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime())
        down_ids = {s.get("indexerId") for s in arr("prowlarr", "indexerstatus") or []
                    if (s.get("disabledTill") or "")[:19] > now}
        down = [i.get("name", "?") for i in idx if i.get("id") in down_ids]
        up = len(idx) - len(down)
        detail = f"{up} de {len(idx)} responden" + (f"; fallan: {', '.join(down)}" if down else "")
        if up == 0:
            if f["active"]:
                c.aviso("Prowlarr", "Indexadores que responden", f"{detail}. {FOOTBALL_MSG}",
                        "Nada: vuelven solos cuando acaba el partido.")
            else:
                c.fallo("Prowlarr", "Indexadores que responden", detail + ": no se puede buscar nada.",
                        "Abre Prowlarr > Indexers y pulsa 'Test All'. Si fallan todos, suele ser la conexión a internet.")
        elif up == 1 and len(idx) > 1:
            c.aviso("Prowlarr", "Indexadores que responden", detail + ": queda uno solo.",
                    "Prowlarr los vuelve a probar solo; si siguen fallando días, quítalos o cámbialos en Prowlarr > Indexers.")
        else:
            c.ok("Prowlarr", "Indexadores que responden", detail)
    if not any("pirate" in (i.get("name") or "").lower() for i in idx):
        return
    if f["active"]:
        c.aviso("Prowlarr", "The Pirate Bay responde", FOOTBALL_MSG,
                "Nada: las búsquedas vuelven solas cuando acaba el partido.")
    elif f["tpb_ok"] is False:
        c.fallo("Prowlarr", "The Pirate Bay responde", "apibay.org no responde y no hay bloqueos de LaLiga activos.",
                "Puede ser una caída de The Pirate Bay: prueba más tarde o añade otro indexador en Prowlarr.")
    else:
        c.ok("Prowlarr", "The Pirate Bay responde")


def check_qbittorrent(c):
    try:
        jar = http.cookiejar.CookieJar()
        op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
        body = urllib.parse.urlencode({"username": QBT_USER, "password": QBT_PASS}).encode()
        bad_login = ("qBittorrent", "Entrar", "No acepta el usuario y la contraseña de .env.",
                     "Comprueba QBT_USER/QBT_PASS en .env.")
        try:
            r = op.open(f"{QBT_URL}/api/v2/auth/login", body, timeout=10).read().decode(errors="replace")
        except urllib.error.HTTPError as e:
            if e.code in (401, 403):
                c.fallo(*bad_login)
                return None
            raise
        # 5.2 responde vacio (antes "Ok.") y la cookie es QBT_SID_<puerto>
        # (antes SID): lo que cuenta es que haya sesion.
        if r.strip() not in ("Ok.", "") or not any("SID" in ck.name for ck in jar):
            c.fallo(*bad_login)
            return None
        prefs = get(f"{QBT_URL}/api/v2/app/preferences", opener=op)
        cats = get(f"{QBT_URL}/api/v2/torrents/categories", opener=op) or {}
    except Exception as e:  # noqa: BLE001
        c.fallo("qBittorrent", "Responde", f"qBittorrent {err(e)}.",
                "Ábrelo desde el panel (botón de qBittorrent) o reinicia el PC.")
        return None
    c.ok("qBittorrent", "Responde")
    if not prefs.get("max_seeding_time_enabled"):
        c.aviso("qBittorrent", "Límite de siembra", "Sin límite de tiempo compartiendo: torrents\\ no se vaciará nunca.",
                "Opciones de qBittorrent > BitTorrent > límite de siembra (72 h).")
    else:
        c.ok("qBittorrent", "Límite de siembra", f"{prefs.get('max_seeding_time', 0) // 60} h")
    if not prefs.get("auto_tmm_enabled"):
        c.aviso("qBittorrent", "Carpetas por categoría", "Modo manual: las descargas no van a torrents\\movies ni torrents\\tv.")
    return cats


def check_bazarr(c):
    key = bazarr_key()
    if not key:
        c.fallo("Bazarr", "Configuración", "No encuentro la clave de Bazarr (config.yaml).")
        return
    h = {"X-API-KEY": key}
    try:
        profiles = get("http://bazarr:6767/api/system/languages/profiles", h) or []
        settings = get("http://bazarr:6767/api/system/settings", h) or {}
        health = (get("http://bazarr:6767/api/system/health", h) or {}).get("data") or []
    except Exception as e:  # noqa: BLE001
        c.fallo("Bazarr", "Responde", f"Bazarr {err(e)}.", "Comprueba que Bazarr está arrancado (scripts\\status.ps1).")
        return
    ids = {p.get("profileId") for p in profiles}
    if not profiles:
        c.fallo("Bazarr", "Perfiles de idioma", "No hay ninguno: no busca subtítulos y no puede guardar series.")
    else:
        c.ok("Bazarr", "Perfiles de idioma", ", ".join(p.get("name", "?") for p in profiles))
    g = settings.get("general") or {}
    for kind, en, prof in (("películas", "movie_default_enabled", "movie_default_profile"),
                           ("series", "serie_default_enabled", "serie_default_profile")):
        if not g.get(en) or g.get(prof) not in ids:
            c.fallo("Bazarr", f"Perfil para {kind} nuevas",
                    f"El perfil por defecto ({g.get(prof)}) no existe o está desactivado: lo nuevo se queda sin subtítulos.")
    if health:
        c.aviso("Bazarr", "Su propia comprobación", "; ".join(f"{x.get('object')}: {x.get('issue')}" for x in health),
                "Abre Bazarr > System > Status.")
    else:
        c.ok("Bazarr", "Su propia comprobación")

    # Lo que Radarr/Sonarr tienen hace rato y Bazarr no conoce (caso real:
    # todas las series fallaban con FOREIGN KEY por el perfil inexistente).
    for app, path, idf, label in (("sonarr", "series", "sonarrSeriesId", "series"),
                                  ("radarr", "movies", "radarrId", "películas")):
        try:
            known = {x.get(idf) for x in (get(f"http://bazarr:6767/api/{path}", h) or {}).get("data") or []}
            items = arr(app, "series" if app == "sonarr" else "movie") or []
        except Exception:  # noqa: BLE001
            continue
        missing = [x.get("title", "?") for x in items
                   if (x.get("statistics", {}).get("episodeFileCount") if app == "sonarr" else x.get("hasFile"))
                   and older_than(x.get("added"), BAZARR_GRACE_S) and x.get("id") not in known]
        if missing:
            c.fallo("Bazarr", f"{label.capitalize()} de {NAMES[app]}",
                    f"{len(missing)} no están en Bazarr (no les buscará subtítulos): {few(missing)}.",
                    "Mira los errores en Bazarr > System > Logs; suele ser un perfil de idioma que falta. " + FIX_BOOTSTRAP)


def check_jellyfin(c):
    key = (seerr_settings().get("jellyfin") or {}).get("apiKey")
    if not key:
        c.aviso("Jellyfin", "Clave", "Seerr no tiene la clave de Jellyfin: no puedo comprobarlo.",
                "Termina el asistente de Seerr (conectarlo con Jellyfin).")
        return
    # Jellyfin 12.2 solo acepta esta cabecera (X-Emby-Token da 401).
    h = {"Authorization": f'MediaBrowser Token="{key}"'}
    jf = "http://jellyfin:8096"
    try:
        libs = get(f"{jf}/Library/VirtualFolders", h) or []
    except Exception as e:  # noqa: BLE001
        c.fallo("Jellyfin", "Acepta la clave", f"Jellyfin {err(e)} con la clave que guarda Seerr.",
                "Si es 401, la clave ya no vale: créala de nuevo en Jellyfin > Panel > Claves API y ponla en Seerr.")
        return
    c.ok("Jellyfin", "Acepta la clave")
    types = {lib.get("CollectionType"): lib for lib in libs}
    for t, label, path in (("movies", "Películas", "/data/media/movies"), ("tvshows", "Series", "/data/media/tv")):
        lib = types.get(t)
        if not lib:
            c.fallo("Jellyfin", f"Biblioteca de {label.lower()}", "No existe.",
                    f"Jellyfin > Panel > Bibliotecas > añadir {label} con la carpeta {path}.")
        elif path not in (lib.get("Locations") or []):
            c.aviso("Jellyfin", f"Biblioteca de {label.lower()}", f"No usa {path} (usa {', '.join(lib.get('Locations') or [])}).")
        else:
            c.ok("Jellyfin", f"Biblioteca de {label.lower()}")

    try:
        task = next((t for t in get(f"{jf}/ScheduledTasks", h) or [] if t.get("Key") == "RefreshLibrary"), None)
        ticks = [tr.get("IntervalTicks") for tr in (task or {}).get("Triggers") or [] if tr.get("Type") == "IntervalTrigger"]
        if not ticks or min(ticks) > 3600 * 10**7:
            c.aviso("Jellyfin", "Escaneo de la biblioteca", "No escanea al menos cada hora: lo nuevo tarda en aparecer.")
        else:
            c.ok("Jellyfin", "Escaneo de la biblioteca", f"cada {min(ticks) // (60 * 10**7)} min")
        if JELLYFIN_HWACCEL:
            enc = get(f"{jf}/System/Configuration/encoding", h) or {}
            if (enc.get("HardwareAccelerationType") or "none") == "none":
                c.aviso("Jellyfin", "GPU", f"Hay GPU ({JELLYFIN_HWACCEL}) pero Jellyfin convierte con el procesador.")
            else:
                c.ok("Jellyfin", "GPU", enc.get("HardwareAccelerationType"))
    except Exception:  # noqa: BLE001
        pass

    # Lo importado hace mas de una hora tiene que estar en la biblioteca.
    try:
        jf_paths = set()
        for kind in ("Movie", "Series"):
            q = urllib.parse.urlencode({"Recursive": "true", "IncludeItemTypes": kind, "Fields": "Path"})
            jf_paths |= {i.get("Path") for i in (get(f"{jf}/Items?{q}", h, timeout=60) or {}).get("Items") or []}
        missing = [m.get("title", "?") for m in arr("radarr", "movie") or []
                   if m.get("hasFile") and older_than((m.get("movieFile") or {}).get("dateAdded"), JELLYFIN_GRACE_S)
                   and (m.get("movieFile") or {}).get("path") not in jf_paths]
        missing += [s.get("title", "?") for s in arr("sonarr", "series") or []
                    if (s.get("statistics") or {}).get("episodeFileCount") and older_than(s.get("added"), JELLYFIN_GRACE_S)
                    and s.get("path") not in jf_paths]
        if missing:
            c.fallo("Jellyfin", "Lo descargado aparece",
                    f"{len(missing)} importados hace más de 1 h no están en Jellyfin: {few(missing)}.",
                    "Jellyfin > Panel > Bibliotecas > Escanear todas las bibliotecas. Si vuelve a pasar: " + FIX_BOOTSTRAP)
        else:
            c.ok("Jellyfin", "Lo descargado aparece")
    except Exception:  # noqa: BLE001
        pass


def check_seerr(c):
    s = seerr_settings()
    key = (s.get("main") or {}).get("apiKey")
    if not key:
        c.aviso("Seerr", "Configuración", "Seerr aún no está configurado (sin clave).",
                "Termina su asistente en http://<IP>:5055.")
        return
    h = {"X-Api-Key": key}
    for app in ("radarr", "sonarr"):
        try:
            servers = [x for x in get(f"http://jellyseerr:5055/api/v1/settings/{app}", h) or [] if not x.get("is4k")]
        except Exception as e:  # noqa: BLE001
            c.fallo("Seerr", "Responde", f"Seerr {err(e)}.")
            return
        if not servers:
            c.fallo("Seerr", f"Conectado con {NAMES[app]}", "No: lo que pidas no se descargará.",
                    f"Seerr > Ajustes > Servicios > añadir {NAMES[app]}.")
        elif any(x.get("activeProfileName") != "Mas seeders" for x in servers):
            c.aviso("Seerr", f"Perfil para {NAMES[app]}",
                    f"Pide con '{servers[0].get('activeProfileName')}' en vez de 'Mas seeders'.")
        else:
            c.ok("Seerr", f"Conectado con {NAMES[app]}", "perfil Mas seeders")
    if not (s.get("jellyfin") or {}).get("apiKey"):
        c.aviso("Seerr", "Conectado con Jellyfin", "No: no sabrá qué tienes ya.")


def run():
    c = Checks()
    sections = (
        ("qBittorrent", check_qbittorrent),
        ("Radarr/Sonarr/Prowlarr", None),
        ("Bazarr", check_bazarr),
        ("Jellyfin", check_jellyfin),
        ("Seerr", check_seerr),
    )
    qbt_cats = None
    for label, fn in sections:
        try:
            if fn is check_qbittorrent:
                qbt_cats = fn(c)
            elif fn is None:
                for app in ("radarr", "sonarr", "prowlarr"):
                    if check_arr(c, app):
                        if app == "prowlarr":
                            check_prowlarr(c)
                        else:
                            check_arr_library(c, app, qbt_cats)
            else:
                fn(c)
        except Exception as e:  # noqa: BLE001 -- una seccion rota no tapa las demas
            c.fallo(label, "Comprobación", f"No se ha podido comprobar: {err(e)}.")
    summary = {lvl: sum(1 for i in c.items if i["level"] == lvl) for lvl in ("ok", "aviso", "fallo")}
    return {"checked_at": int(time.time()), "summary": summary, "checks": c.items}


def main():
    r = run()
    if "--json" in sys.argv:
        # ASCII (\u00e1...): la salida pasa por cmd /c y PowerShell 5.1 la leeria
        # con la pagina de codigos de la consola (tildes rotas).
        print(json.dumps(r))
    else:
        marks = {"ok": "  ok  ", "aviso": "AVISO ", "fallo": "FALLO "}
        for i in r["checks"]:
            print(f"[{marks[i['level']]}] {i['app']}: {i['name']}" + (f" -- {i['detail']}" if i["detail"] else ""))
            if i["fix"]:
                print(f"          Qué hacer: {i['fix']}")
        s = r["summary"]
        print(f"\nResultado: {s['ok']} bien, {s['aviso']} avisos, {s['fallo']} fallos.")
    sys.exit(1 if r["summary"]["fallo"] else 0)


if __name__ == "__main__":
    main()
