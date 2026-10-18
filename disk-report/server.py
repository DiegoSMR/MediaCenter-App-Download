#!/usr/bin/env python3
# =============================================================================
# disk-report — informe de espacio en disco (spec 021).
#
# Recorre /data (todo ${DATA_ROOT}, montado de una pieza igual que en
# Radarr/Sonarr, para que los inodos y el contador de hardlinks sean los
# mismos que ven ellos) y /config (${CONFIG_ROOT}), y sirve una pagina con:
#   - archivos "fantasma": en /data/torrents con contador de enlaces 1, es
#     decir, sin hardlink en la biblioteca (/data/media). Ocupan espacio
#     completo y Jellyfin no los ve. Comprobado que el contador de enlaces
#     de NTFS se ve bien a traves del bind mount de Docker Desktop.
#   - restos en torrents/incomplete que qBittorrent ya no esta descargando.
#   - peso de cada carpeta y espacio libre del disco.
#
# Fase 1: solo lectura (los montajes son :ro). Recorrer ~3.000 archivos
# cuesta ~10 s en esta maquina, asi que se re-escanea cada hora y a
# peticion desde la pagina.
# =============================================================================
import calendar
import http.cookiejar
import json
import os
import re
import shutil
import socket
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import verify  # comprobacion de la instalacion (spec 049), en /app como este

DATA = "/data"
CONFIG = "/config"
TORRENTS = os.path.join(DATA, "torrents")
MEDIA = os.path.join(DATA, "media")
# Rutas tal como las ve qBittorrent (ver su bloque en docker-compose.yml).
QBT_INCOMPLETE = "/incomplete-fast"
# qBittorrent nativo en Windows (spec 013): su DATA_ROOT, p.ej. D:/MEDIA/data.
HOST_DATA_ROOT = os.environ.get("HOST_DATA_ROOT", "").replace("\\", "/").rstrip("/")
INCOMPLETE_DIRS = {"incomplete", "_incomplete"}
# Subcarpetas de categoria dentro de torrents/: su contenido son torrents,
# no un torrent en si. Se amplia con las rutas de categoria de qBittorrent.
CATEGORY_DIRS = {"movies", "tv"}
# Carpetas que contienen torrents pero no son uno (ver torrent_for).
CONTAINER_DIRS = {TORRENTS} | {os.path.join(TORRENTS, d) for d in INCOMPLETE_DIRS | CATEGORY_DIRS}

INTERVAL_S = float(os.environ.get("DISK_REPORT_INTERVAL_HOURS", "1")) * 3600
WARN_PERCENT = float(os.environ.get("DISK_REPORT_WARN_PERCENT", "5"))
# Por debajo de este tamano un archivo no cuenta para decidir si un torrent
# esta en la biblioteca o no (.nfo, .txt, muestras, portadas...).
MIN_SIGNIFICANT = int(os.environ.get("DISK_REPORT_MIN_FILE_MB", "50")) * 2**20
CONFIG_MAX_AGE_S = 6 * 3600
RECENT_S = float(os.environ.get("DISK_REPORT_RECENT_HOURS", "24")) * 3600
QBT_URL = os.environ.get("QBT_URL", "http://qbittorrent:8080")
QBT_USER = os.environ.get("QBT_USER", "admin")
QBT_PASS = os.environ.get("QBT_PASS", "adminadmin")
PORT = 8080
# Parar/continuar descargas y descargas atascadas (spec 028).
STATE_FILE = os.environ.get("DISK_REPORT_STATE", "/state/state.json")
MIN_FREE = float(os.environ.get("DISK_MIN_FREE_GB", "50")) * 2**30
RESUME_MARGIN = 20 * 2**30
STALLED_S = float(os.environ.get("STALLED_HOURS", "6")) * 3600
GUARD_S = 60
PAUSE_TAG = "mediacenter-pausa"
# "Ya visto" (spec 040): lo visto en Jellyfin hace mas de estos dias.
WATCHED_S = float(os.environ.get("WATCHED_DAYS", "30")) * 86400
HOMER_PORT = os.environ.get("HOMER_PORT", "3000")
HOST_LAN_IP = os.environ.get("HOST_LAN_IP", "")
STATIC =os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")


def log(msg):
    print(f"[disk-report] {msg}", file=sys.stderr, flush=True)


# ---------------------------------------------------------------------------
# qBittorrent
# ---------------------------------------------------------------------------
def qbt_torrents():
    """Devuelve (torrents, rutas de categoria) o (None, set()) si no hay
    acceso. Sin qBittorrent el informe sale igual, con esa columna en
    "desconocido"."""
    try:
        jar = http.cookiejar.CookieJar()
        opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
        body = urllib.parse.urlencode({"username": QBT_USER, "password": QBT_PASS}).encode()
        opener.open(f"{QBT_URL}/api/v2/auth/login", body, timeout=10).read()
        torrents = json.load(opener.open(f"{QBT_URL}/api/v2/torrents/info", timeout=20))
        cats = json.load(opener.open(f"{QBT_URL}/api/v2/torrents/categories", timeout=10))
        cat_paths = {c.get("savePath", "").rstrip("/") for c in cats.values()}
        return torrents, {p for p in cat_paths if p}
    except Exception as e:  # noqa: BLE001 -- cualquier fallo = "desconocido"
        log(f"qBittorrent no disponible ({e}); se informa sin esa columna.")
        return None, set()


def to_local(qbt_path):
    """Ruta de qBittorrent -> ruta en este contenedor. Con qBittorrent
    nativo en Windows (spec 013) llegan rutas como D:\\MEDIA\\data\\torrents\\X:
    HOST_DATA_ROOT (el DATA_ROOT de .env) se traduce a /data."""
    p = qbt_path.replace("\\", "/").rstrip("/")
    if HOST_DATA_ROOT and (p.lower() == HOST_DATA_ROOT.lower() or p.lower().startswith(HOST_DATA_ROOT.lower() + "/")):
        return DATA + p[len(HOST_DATA_ROOT):]
    if p == QBT_INCOMPLETE or p.startswith(QBT_INCOMPLETE + "/"):
        return os.path.join(TORRENTS, "incomplete") + p[len(QBT_INCOMPLETE):]
    return p


def torrent_for(path, torrents):
    """El torrent de qBittorrent cuyo contenido es (o contiene) `path`."""
    if torrents is None:
        return None
    for t in torrents:
        cp = to_local(t.get("content_path", ""))
        # Un torrent de varios archivos guardado "sin subcarpeta" tiene como
        # content_path la propia carpeta de descargas: no identifica nada.
        if cp in CONTAINER_DIRS or not cp.startswith(TORRENTS + "/"):
            continue
        if (cp == path or cp.startswith(path + "/") or path.startswith(cp + "/")):
            return t
    return None


def torrent_info(t):
    if t is None:
        return None
    return {
        "name": t.get("name"),
        "hash": t.get("hash"),
        "state": t.get("state"),
        "category": t.get("category"),
        "progress": t.get("progress"),
        "completion_on": t.get("completion_on") if (t.get("completion_on") or 0) > 0 else None,
    }


# ---------------------------------------------------------------------------
# Radarr/Sonarr: a que pelicula/serie pertenece cada descarga fantasma y si
# la biblioteca la tiene. Es lo que distingue "version sustituida, se puede
# borrar" de "se ha quedado fuera de Jellyfin, habria que importarla".
# ---------------------------------------------------------------------------
ARRS = {"radarr": "http://radarr:7878", "sonarr": "http://sonarr:8989"}


def arr_key(app):
    try:
        with open(os.path.join(CONFIG, app, "config.xml"), encoding="utf-8") as f:
            m = re.search(r"<ApiKey>(.*?)</ApiKey>", f.read())
        return m.group(1) if m else None
    except OSError:
        return None


def arr_get(app, path):
    """GET a la API v3; None si da 404 (p.ej. pelicula borrada de Radarr)."""
    req = urllib.request.Request(f"{ARRS[app]}/api/v3/{path}", headers={"X-Api-Key": arr_key(app) or ""})
    try:
        return json.load(urllib.request.urlopen(req, timeout=20))
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise


def arr_post(app, path, body):
    req = urllib.request.Request(f"{ARRS[app]}/api/v3/{path}", data=json.dumps(body).encode(), method="POST",
                                 headers={"X-Api-Key": arr_key(app) or "", "Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=30))


def arr_put(app, path, body):
    req = urllib.request.Request(f"{ARRS[app]}/api/v3/{path}", data=json.dumps(body).encode(), method="PUT",
                                 headers={"X-Api-Key": arr_key(app) or "", "Content-Type": "application/json"})
    urllib.request.urlopen(req, timeout=30).read()


VIDEO_EXT = {".mkv", ".mp4", ".avi", ".m4v", ".ts", ".wmv", ".mov", ".webm"}
EXTRAS_RE = re.compile(r"(?<![a-z])(featurettes?|extras?|bonus|behind.the.scenes|deleted.scenes?|interviews?|"
                       r"trailers?|samples?|soundtracks?|making.of)(?![a-z])", re.I)


def sonarr_files(ghost_files):
    """Para una serie, comprueba CADA archivo fantasma por separado con
    /parse de Sonarr (que episodio es y si la biblioteca lo tiene). El
    historial de la descarga no basta: en un pack importado a medias solo
    recoge los episodios que Sonarr llego a importar de el."""
    episodes, missing, doubtful = 0, 0, []
    for name in ghost_files:
        r = arr_get("sonarr", "parse?" + urllib.parse.urlencode({"title": os.path.basename(name)})) or {}
        eps = r.get("episodes") or []
        if not eps:
            # No es un episodio: extra (featurette, banda sonora...) si lo
            # parece; si es un video sin pinta de extra, mejor no suponer.
            if os.path.splitext(name)[1].lower() in VIDEO_EXT and not EXTRAS_RE.search(name):
                doubtful.append(name)
            continue
        episodes += len(eps)
        missing += sum(1 for e in eps if e.get("monitored") and not e.get("hasFile"))
    return episodes, missing, doubtful


def arr_lookup(torrent_hash, ghost_files):
    """Que dicen Radarr/Sonarr de la descarga con este hash. None si ninguno
    la conoce (descarga manual) o no se les puede preguntar."""
    for app in ARRS:
        try:
            hist = arr_get(app, f"history?pageSize=100&downloadId={torrent_hash.upper()}") or {}
            recs = hist.get("records", [])
            if not recs:
                continue
            if app == "radarr":
                movie_id = recs[0].get("movieId")
                m = arr_get(app, f"movie/{movie_id}")
                if m is None:
                    return {"app": app, "verdict": "gone"}
                return {"app": app, "id": movie_id, "title": m.get("title"), "year": m.get("year"),
                        "verdict": "replaced" if m.get("hasFile") else "missing"}
            series_id = recs[0].get("seriesId")
            s = arr_get(app, f"series/{series_id}")
            if s is None:
                return {"app": app, "verdict": "gone"}
            episodes, missing, doubtful = sonarr_files(ghost_files)
            if doubtful and not missing:
                # Nombres que /parse no entiende (p.ej. "clue-sun404.avi"):
                # si el historial de esta descarga dice que le faltan
                # episodios a la biblioteca, lo mas probable es que sean
                # esos -> se trata como rescatable, no como dudoso.
                ep_ids = sorted({r["episodeId"] for r in recs if r.get("episodeId")})
                if ep_ids:
                    hist = arr_get(app, "episode?" + urllib.parse.urlencode([("episodeIds", i) for i in ep_ids])) or []
                    hist_missing = sum(1 for e in hist if e.get("monitored") and not e.get("hasFile"))
                    if hist_missing:
                        episodes, missing = len(hist), hist_missing
            verdict = "missing" if missing else "doubtful" if doubtful else "replaced"
            return {"app": app, "id": series_id, "title": s.get("title"), "year": s.get("year"), "verdict": verdict,
                    "episodes": episodes, "episodes_missing": missing, "doubtful": doubtful}
        except Exception as e:  # noqa: BLE001 -- sin respuesta = "desconocido"
            log(f"{app} no responde ({e}); sin ese dato.")
            return {"app": app, "verdict": "error"}
    return None


# ---------------------------------------------------------------------------
# Escaneo
# ---------------------------------------------------------------------------
def walk_files(top):
    """Lista de (ruta, stat) de todos los archivos bajo `top`, sin seguir
    enlaces simbolicos."""
    out = []
    for root, dirs, files in os.walk(top, onerror=lambda e: log(f"no se puede leer: {e}")):
        for f in files:
            p = os.path.join(root, f)
            try:
                out.append((p, os.lstat(p)))
            except OSError as e:
                log(f"no se puede leer: {e}")
    return out


def children(top):
    try:
        return sorted(os.scandir(top), key=lambda e: e.name.lower())
    except OSError:
        return []


def size_of(files):
    return sum(st.st_size for _, st in files)


def child_sizes(top, files):
    """Peso de cada hijo directo de `top`, a partir de la lista de archivos
    ya recorrida (sin volver a tocar el disco)."""
    sizes = {}
    prefix = top.rstrip("/") + "/"
    for p, st in files:
        if p.startswith(prefix):
            name = p[len(prefix):].split("/", 1)[0]
            sizes[name] = sizes.get(name, 0) + st.st_size
    return sorted(({"name": n, "bytes": b} for n, b in sizes.items()), key=lambda x: -x["bytes"])


def disk_usage(path):
    st = os.statvfs(path)
    total = st.f_blocks * st.f_frsize
    free = st.f_bavail * st.f_frsize
    return {"total": total, "free": free, "used": total - st.f_bfree * st.f_frsize}


def torrent_groups(files, cat_dirs):
    """Agrupa los archivos de torrents/ por torrent: cada hijo de torrents/
    es un torrent (carpeta o archivo suelto), salvo las carpetas de
    categoria (se baja un nivel) y las de descargas a medias (aparte)."""
    groups = {}
    prefix = TORRENTS + "/"
    for p, st in files:
        if not p.startswith(prefix):
            continue
        parts = p[len(prefix):].split("/")
        if parts[0] in INCOMPLETE_DIRS:
            continue
        depth = 2 if parts[0] in cat_dirs and len(parts) > 1 else 1
        key = TORRENTS + "/" + "/".join(parts[:depth])
        groups.setdefault(key, []).append((p, st))
    return groups


def classify(path, gfiles, torrents, now):
    ghost = [(p, st) for p, st in gfiles if st.st_nlink == 1]
    ghost_big = [x for x in ghost if x[1].st_size >= MIN_SIGNIFICANT]
    linked_big = [x for x in gfiles if x[1].st_nlink > 1 and x[1].st_size >= MIN_SIGNIFICANT]
    if not ghost_big:
        return None
    t = torrent_for(path, torrents)
    newest = max(st.st_mtime for _, st in gfiles)
    if t and (t.get("completion_on") or 0) > 0:
        newest = max(newest, t["completion_on"])
    return {
        "path": path,
        "name": os.path.relpath(path, TORRENTS),
        # "fantasma": nada de este torrent esta en la biblioteca.
        # "parcial": parte si (p.ej. un pack de temporada importado a
        # medias) -- solo es recuperable la parte fantasma.
        "status": "parcial" if linked_big else "fantasma",
        "ghost_bytes": sum(st.st_size for _, st in ghost),
        "total_bytes": size_of(gfiles),
        # "Reciente" = puede que Radarr/Sonarr aun la esten importando. Eso
        # solo pasa si qBittorrent todavia la tiene: si ya no la tiene (o
        # nunca la tuvo), la fecha del archivo no significa nada -- p.ej.
        # tras quitar la serie de la biblioteca con la X (spec 026).
        "recent": (t is not None or torrents is None) and now - newest < RECENT_S,
        "modified": int(newest),
        "files": sorted(
            ({"name": os.path.relpath(p, path) if p != path else os.path.basename(p),
              "bytes": st.st_size} for p, st in ghost_big),
            key=lambda x: -x["bytes"]),
        "linked_files": len(linked_big),
        "qbt": torrent_info(t),
        "arr": arr_lookup(t["hash"], [os.path.relpath(p, path) if p != path else os.path.basename(p)
                                      for p, _ in ghost_big]) if t else None,
    }


# ---------------------------------------------------------------------------
# Borrado (fase 2) -- lo usan el boton de la pagina y clean.py.
#
# Solo se puede borrar lo que no hace falta para nada: Radarr/Sonarr ya
# tienen otra version en la biblioteca, o ya no gestionan esa pelicula/
# serie. Nunca lo que se ha quedado fuera de Jellyfin (se rescata con
# Importacion manual), lo reciente (puede estar pendiente de importar) ni
# lo dudoso. Las descargas que Radarr/Sonarr no conocen (manuales) solo con
# include_unknown. Es la regla de clean.py y del borrado en bloque; desde la
# spec 033 la pagina puede saltarsela UNA a UNA tras avisar (allow_risky).
#
# Montaje: /data de solo lectura y /data/torrents con escritura encima ->
# fisicamente no se puede tocar la biblioteca. Aun asi, justo antes de
# borrar se vuelve a analizar la descarga (fresh_ghost) y cada archivo.
# ---------------------------------------------------------------------------
def block_reason(g, include_unknown):
    """None si se puede borrar; si no, el motivo en palabras."""
    a = g.get("arr")
    verdict = a["verdict"] if a else "unknown"
    if g["recent"]:
        return "reciente: puede estar pendiente de importar"
    if verdict == "missing":
        return "se ha quedado fuera de Jellyfin: rescátala con Importación manual"
    if verdict == "doubtful":
        return f"Sonarr no reconoce {len(a['doubtful'])} vídeo(s) como episodio: revísalos a mano"
    if verdict == "error":
        return "Radarr/Sonarr no responden: no se sabe si hace falta"
    if verdict == "unknown" and not include_unknown:
        return "Radarr/Sonarr no la conocen (descarga manual)"
    return None


def inside_torrents(path):
    real = os.path.realpath(path)
    if not real.startswith(TORRENTS + "/") or real in CONTAINER_DIRS:
        return False
    return real[len(TORRENTS) + 1:].split("/", 1)[0] not in INCOMPLETE_DIRS


def files_under(path):
    if os.path.isfile(path):
        return [path]
    return [os.path.join(r, f) for r, _, fs in os.walk(path) for f in fs]


def check_whole(path):
    """Para borrar una descarga entera: NINGUN archivo grande puede estar en
    la biblioteca. Devuelve el motivo si no se puede, o None."""
    if not inside_torrents(path):
        return "ruta fuera de torrents/ (o en incomplete/)"
    if not os.path.exists(path):
        return "ya no existe"
    for f in files_under(path):
        st = os.lstat(f)
        if st.st_nlink > 1 and st.st_size >= MIN_SIGNIFICANT:
            return f"{os.path.basename(f)} está en la biblioteca"
    return None


def check_file(path):
    if not inside_torrents(path):
        return "ruta fuera de torrents/ (o en incomplete/)"
    if not os.path.isfile(path):
        return "ya no existe"
    if os.lstat(path).st_nlink != 1:
        return "está en la biblioteca"
    return None


class Qbt:
    def __init__(self):
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        body = urllib.parse.urlencode({"username": QBT_USER, "password": QBT_PASS}).encode()
        self.opener.open(f"{QBT_URL}/api/v2/auth/login", body, timeout=10).read()

    def delete(self, torrent_hash, delete_files):
        body = urllib.parse.urlencode({"hashes": torrent_hash, "deleteFiles": str(delete_files).lower()}).encode()
        self.opener.open(f"{QBT_URL}/api/v2/torrents/delete", body, timeout=20).read()

    def torrents(self, **params):
        q = urllib.parse.urlencode(params)
        return json.load(self.opener.open(f"{QBT_URL}/api/v2/torrents/info?{q}", timeout=20))

    def call(self, action, hashes, **extra):
        """stop/start/addTags/removeTags sobre varios torrents. qBittorrent 5
        (WebAPI 2.11+) llama stop/start a lo que antes era pause/resume."""
        body = urllib.parse.urlencode({"hashes": "|".join(hashes), **extra}).encode()
        self.opener.open(f"{QBT_URL}/api/v2/torrents/{action}", body, timeout=20).read()


def wait_gone(path, seconds=30):
    for _ in range(seconds):
        if not os.path.exists(path):
            return True
        time.sleep(1)
    return False


def delete_ghost(g, qbt):
    """Devuelve bytes liberados. Lanza excepcion con el motivo si no borra."""
    t = g.get("qbt")
    if g["status"] == "fantasma":
        reason = check_whole(g["path"])
        if reason:
            raise RuntimeError(reason)
        freed = g["ghost_bytes"]
        if t and qbt:
            # qBittorrent borra el torrent y sus archivos: no queda un
            # torrent roto en su lista.
            qbt.delete(t["hash"], True)
            if wait_gone(g["path"]):
                return freed
            log("qBittorrent no lo ha borrado en 30 s; se borra directamente.")
            reason = check_whole(g["path"])
            if reason:
                raise RuntimeError(reason)
        if os.path.isdir(g["path"]):
            shutil.rmtree(g["path"])
        else:
            os.remove(g["path"])
        return freed

    # Parcial: solo los archivos fuera de la biblioteca. El torrent se quita
    # de qBittorrent SIN borrar archivos (si no, al faltarle unos pocos se
    # quedaria en error); lo que esta en la biblioteca no ocupa extra.
    targets = [os.path.join(g["path"], f["name"]) for f in g["files"]]
    for p in targets:
        reason = check_file(p)
        if reason:
            raise RuntimeError(f"{os.path.basename(p)}: {reason}")
    if t and qbt:
        qbt.delete(t["hash"], False)
    freed = 0
    for p in targets:
        freed += os.lstat(p).st_size
        os.remove(p)
    return freed


def fresh_ghost(path):
    """Vuelve a analizar UNA descarga ahora mismo (no se fia del ultimo
    escaneo): None si ya no es fantasma o ya no existe."""
    if not inside_torrents(path) or not os.path.exists(path):
        return None
    torrents, _ = qbt_torrents()
    files = [(p, os.lstat(p)) for p in files_under(path)]
    return classify(path, files, torrents, time.time()) if files else None


# ---------------------------------------------------------------------------
# Importacion (spec 024) -- lo que se ha quedado fuera de la biblioteca.
#
# Radarr/Sonarr no importan solos cuando el release se asocio "por ID" y no
# por titulo ("Manual Import required"), ni cuando creen que ya lo
# importaron pero el archivo de la biblioteca ya no esta. Aqui se hace la
# Importacion manual por ellos, pero SOLO sin duda posible (ver
# import_plan); lo dudoso queda en la pagina con su motivo o con boton.
# Modo "copy" = hardlink: sin espacio extra, el torrent sigue compartiendose.
# ---------------------------------------------------------------------------
AUTO_IMPORT = os.environ.get("DISK_REPORT_AUTO_IMPORT", "true").lower() != "false"
# Margen para que Radarr/Sonarr importen ellos si iban a hacerlo.
AUTO_IMPORT_AFTER_S = float(os.environ.get("DISK_REPORT_AUTO_IMPORT_AFTER_HOURS", "2")) * 3600
imports_log = []          # ultimas importaciones, para la pagina
failed_imports = {}       # ruta -> fecha de la descarga: no reintentar en bucle


def import_plan(g):
    """(app, archivos para ManualImport) de una descarga que se ha quedado
    fuera. Lanza RuntimeError con el motivo si no se puede decidir solo."""
    a = g.get("arr")
    if not a or a.get("verdict") != "missing" or not a.get("id"):
        raise RuntimeError("no está pendiente de importar")
    app, path = a["app"], g["path"]
    dl = g["qbt"]["hash"].upper() if g.get("qbt") else None
    full = (lambda f: path) if os.path.isfile(path) else (lambda f: os.path.join(path, f["name"]))
    vids = [f for f in g["files"]
            if os.path.splitext(f["name"])[1].lower() in VIDEO_EXT and not EXTRAS_RE.search(f["name"])]

    if app == "radarr":
        if len(vids) != 1:
            raise RuntimeError(f"tiene {len(vids)} vídeos principales: elige cuál en Radarr → Importación manual")
        info = {}
        for title in (os.path.splitext(os.path.basename(path))[0], os.path.splitext(os.path.basename(vids[0]["name"]))[0]):
            info = (arr_get("radarr", "parse?" + urllib.parse.urlencode({"title": title})) or {}).get("parsedMovieInfo") or {}
            if info.get("quality"):
                break
        if not info.get("quality"):
            raise RuntimeError("Radarr no reconoce la calidad del archivo: Importación manual en Radarr")
        item = {"path": full(vids[0]), "movieId": a["id"], "quality": info["quality"],
                "languages": info.get("languages") or [], "releaseGroup": info.get("releaseGroup") or "",
                "indexerFlags": 0}
        if dl:
            item["downloadId"] = dl
        return app, [item]

    items = []
    for f in vids:
        r = arr_get("sonarr", "parse?" + urllib.parse.urlencode({"title": os.path.basename(f["name"])})) or {}
        eps = r.get("episodes") or []
        # Solo episodios de ESA serie que no tengan ya archivo.
        if not eps or (r.get("series") or {}).get("id") != a["id"] or any(e.get("hasFile") for e in eps):
            continue
        info = r.get("parsedEpisodeInfo") or {}
        if not info.get("quality"):
            continue
        item = {"path": full(f), "seriesId": a["id"], "episodeIds": [e["id"] for e in eps],
                "quality": info["quality"], "languages": info.get("languages") or [],
                "releaseGroup": info.get("releaseGroup") or "", "indexerFlags": 0, "releaseType": "singleEpisode"}
        if dl:
            item["downloadId"] = dl
        items.append(item)
    if not items:
        raise RuntimeError("Sonarr no reconoce qué episodios son: Importación manual en Sonarr")
    return app, items


def do_import(app, items):
    cmd = arr_post(app, "command", {"name": "ManualImport", "importMode": "copy", "files": items})
    st = cmd
    for _ in range(150):
        st = arr_get(app, f"command/{cmd['id']}") or {}
        if st.get("status") in ("completed", "failed", "aborted"):
            break
        time.sleep(2)
    if st.get("status") != "completed":
        raise RuntimeError(f"{app}: {st.get('message') or st.get('status')}")
    return st.get("message") or "importado"


def record_import(g, ok, msg, auto):
    a = g.get("arr") or {}
    imports_log.insert(0, {"name": g["name"], "title": a.get("title"), "ok": ok, "message": msg,
                           "auto": auto, "at": int(time.time())})
    del imports_log[20:]
    log(f"{'IMPORTADO' if ok else 'NO importado'} ({'auto' if auto else 'boton'}): {g['name']} -> {msg}")


def annotate_imports(ghosts):
    """Para la pagina: si cada descarga que falta se puede importar, y si se
    importara sola."""
    missing = [g for g in ghosts if (g.get("arr") or {}).get("verdict") == "missing"]
    per_item = {}
    for g in missing:
        k = (g["arr"]["app"], g["arr"].get("id"))
        per_item[k] = per_item.get(k, 0) + 1
    for g in missing:
        try:
            import_plan(g)
            g["import_blocked"] = None
        except Exception as e:  # noqa: BLE001
            g["import_blocked"] = str(e)
        n = per_item[(g["arr"]["app"], g["arr"].get("id"))]
        # Solo pelicula: en series, varias descargas pueden aportar
        # episodios distintos y cada archivo ya se comprueba por separado.
        g["import_choose"] = n if n > 1 and g["arr"]["app"] == "radarr" else 0


def auto_import(report):
    """Importa lo que no admite duda. Devuelve cuantas descargas importo."""
    done = 0
    for g in report["ghosts"]:
        if (g.get("arr") or {}).get("verdict") != "missing" or g.get("import_blocked") or g.get("import_choose"):
            continue
        if time.time() - g["modified"] < AUTO_IMPORT_AFTER_S:
            continue
        if failed_imports.get(g["path"]) == g["modified"]:
            continue
        try:
            app, items = import_plan(g)
            record_import(g, True, do_import(app, items), auto=True)
            done += 1
        except Exception as e:  # noqa: BLE001
            failed_imports[g["path"]] = g["modified"]
            record_import(g, False, str(e), auto=True)
    return done


def import_paths(paths):
    """Boton "Importar" de la pagina: misma proteccion que el borrado."""
    with lock:
        known = {g["path"] for g in (state["report"] or {}).get("ghosts", [])}
    results = []
    for p in paths:
        r = {"path": p, "ok": False}
        results.append(r)
        if not isinstance(p, str) or p not in known:
            r["error"] = "no está en la lista"
            continue
        try:
            g = fresh_ghost(p)
            if g is None:
                raise RuntimeError("ya no está fuera de la biblioteca (o ya no existe)")
            app, items = import_plan(g)
            r["message"] = do_import(app, items)
            r["ok"] = True
            record_import(g, True, r["message"], auto=False)
        except Exception as e:  # noqa: BLE001
            r["error"] = str(e)
    return results


# ---------------------------------------------------------------------------
# Borrar de la biblioteca (spec 025) -- la X de "lo que mas ocupa".
#
# Lo borran Radarr/Sonarr (quitar la pelicula/serie + sus archivos): si
# solo se borraran los archivos, la volverian a descargar. Sin papelera
# (spec 026): se borran al momento. disk-report sigue sin escribir en /data/media.
# Ademas se borran sus descargas (torrent + archivos de torrents/), que
# por el hardlink seguirian ocupando lo mismo.
# ---------------------------------------------------------------------------
LIB_ROOTS = {"radarr": os.path.join(MEDIA, "movies"), "sonarr": os.path.join(MEDIA, "tv")}


def arr_delete(app, path):
    req = urllib.request.Request(f"{ARRS[app]}/api/v3/{path}", method="DELETE",
                                 headers={"X-Api-Key": arr_key(app) or ""})
    urllib.request.urlopen(req, timeout=120).read()


def library_index():
    """{app: {nombre de carpeta: {id, title, year}}} para poner la X solo en
    lo que Radarr/Sonarr gestionan."""
    idx = {}
    for app, kind in (("radarr", "movie"), ("sonarr", "series")):
        try:
            idx[app] = {os.path.basename(x["path"].rstrip("/")): {"id": x["id"], "title": x["title"], "year": x.get("year")}
                        for x in arr_get(app, kind) or []}
        except Exception as e:  # noqa: BLE001 -- sin X, pero el informe sale
            log(f"{app} no responde para la lista de la biblioteca ({e}).")
            idx[app] = {}
    return idx


def library_downloads(app, item_id, lib_path):
    """Torrents de esta pelicula/serie que se pueden borrar sin tocar nada
    mas: [(torrent, bytes)], y los que no, con el motivo."""
    kind = "movie?movieId" if app == "radarr" else "series?seriesId"
    hashes = {r["downloadId"].lower() for r in arr_get(app, f"history/{kind}={item_id}") or [] if r.get("downloadId")}
    torrents, _ = qbt_torrents()
    if torrents is None:
        raise RuntimeError("qBittorrent no responde: no se borra nada")
    # Inodo de cada archivo de la biblioteca de ESTA pelicula/serie: un
    # archivo de la descarga enlazado a otra cosa no se toca.
    own = {os.lstat(f).st_ino for f in files_under(lib_path)} if os.path.isdir(lib_path) else set()
    ok, skipped = [], []
    for t in torrents:
        if t["hash"].lower() not in hashes:
            continue
        cp = to_local(t.get("content_path", ""))
        if not inside_torrents(cp):
            skipped.append((t, "su ruta no está dentro de torrents/"))
            continue
        files = [(f, os.lstat(f)) for f in files_under(cp)] if os.path.exists(cp) else []
        foreign = [f for f, st in files if st.st_nlink > 1 and st.st_ino not in own]
        if foreign:
            skipped.append((t, f"comparte archivos con otra cosa de la biblioteca ({os.path.basename(foreign[0])})"))
            continue
        ok.append((t, sum(st.st_size for _, st in files)))
    return ok, skipped


def remove_library(app, item_id):
    kind = "movie" if app == "radarr" else "series"
    item = arr_get(app, f"{kind}/{item_id}")
    if item is None:
        raise RuntimeError("ya no está en " + app.capitalize())
    lib_path = item["path"].rstrip("/")
    if os.path.dirname(lib_path) != LIB_ROOTS[app]:
        raise RuntimeError(f"su carpeta no está en la biblioteca ({lib_path})")
    lib_files = [(f, os.lstat(f)) for f in files_under(lib_path)] if os.path.isdir(lib_path) else []
    lib_bytes = sum(st.st_size for _, st in lib_files)
    # Inodos de la biblioteca de esto: sirven para encontrar sus copias
    # enlazadas en torrents/ aunque qBittorrent ya no tenga el torrent.
    lib_inodes = {st.st_ino for _, st in lib_files if st.st_nlink > 1}
    downloads, skipped = library_downloads(app, item_id, lib_path)  # antes: al borrar se pierde el historial
    title = f"{item.get('title')} ({item.get('year')})"
    # 1) Radarr/Sonarr: fuera de su lista y archivos borrados (sin papelera
    #    desde la spec 026).
    arr_delete(app, f"{kind}/{item_id}?deleteFiles=true&addImportExclusion=false")
    # 2) Sus descargas en qBittorrent (torrent + archivos).
    freed = 0
    if downloads:
        qbt = Qbt()
        for t, b in downloads:
            qbt.delete(t["hash"], True)
            freed += b
        for t, _ in downloads:
            wait_gone(to_local(t.get("content_path", "")), 30)
    # 3) Copias enlazadas que siguen en torrents/ sin torrent (p.ej. tras
    #    borrar antes los fantasmas de un pack parcial, spec 026).
    freed += remove_linked_leftovers(lib_inodes)
    # 4) Jellyfin y Seerr (antes Jellyseerr).
    extra = forget_everywhere(app, item, lib_path)
    log(f"QUITADO de la biblioteca: {title} [{app}] -> biblioteca {fmt(lib_bytes)}, descargas {fmt(freed)}; {extra}"
        + (f"; no tocadas: {[(t['name'], why) for t, why in skipped]}" if skipped else ""))
    return {"title": title, "library_bytes": lib_bytes, "downloads_bytes": freed,
            "downloads": len(downloads), "skipped": [f"{t['name']}: {why}" for t, why in skipped],
            "elsewhere": extra}


def remove_linked_leftovers(lib_inodes):
    """Borra de torrents/ los archivos que eran hardlink de lo que se acaba
    de quitar. Si una carpeta de descarga se queda sin ningun archivo
    grande, se borra entera (.nfo, muestras...). Solo archivos que ya no
    tienen otro enlace."""
    if not lib_inodes:
        return 0
    files = [(p, st) for p, st in walk_files(TORRENTS)
             if p[len(TORRENTS) + 1:].split("/", 1)[0] not in INCOMPLETE_DIRS]
    freed = 0
    for gpath, gfiles in torrent_groups(files, CATEGORY_DIRS).items():
        hits = [(p, st) for p, st in gfiles if st.st_ino in lib_inodes]
        if not hits:
            continue
        for p, _ in hits:
            st = os.lstat(p)
            if st.st_nlink == 1 and inside_torrents(p):
                os.remove(p)
                freed += st.st_size
        rest = [p for p in files_under(gpath) if os.path.getsize(p) >= MIN_SIGNIFICANT] if os.path.exists(gpath) else []
        if not rest and os.path.isdir(gpath) and inside_torrents(gpath):
            freed += sum(os.lstat(p).st_size for p in files_under(gpath))
            shutil.rmtree(gpath)
    return freed


def service_key(path, *keys):
    try:
        with open(os.path.join(CONFIG, path), encoding="utf-8") as f:
            v = json.load(f)
        for k in keys:
            v = v[k]
        return v
    except (OSError, KeyError, ValueError):
        return None


def forget_everywhere(app, item, lib_path):
    """Quita de Jellyfin y Jellyseerr lo que se acaba de borrar. Devuelve
    un resumen; un fallo aqui no deshace lo anterior (ya esta borrado)."""
    out = []
    # Jellyfin: le avisa de que la ruta ya no existe (lo mismo que hace la
    # conexion Radarr/Sonarr -> Jellyfin); si aun asi sigue, se quita el
    # elemento a mano.
    key = service_key("jellyseerr/settings.json", "jellyfin", "apiKey")
    if key:
        try:
            h = {"Authorization": f'MediaBrowser Token="{key}"', "Content-Type": "application/json"}
            body = json.dumps({"Updates": [{"Path": lib_path, "UpdateType": "Deleted"}]}).encode()
            urllib.request.urlopen(urllib.request.Request("http://jellyfin:8096/Library/Media/Updated", data=body,
                                                          headers=h, method="POST"), timeout=20).read()
            kind = "Movie" if app == "radarr" else "Series"
            left = []
            for _ in range(10):
                q = urllib.parse.urlencode({"Recursive": "true", "IncludeItemTypes": kind, "Fields": "Path",
                                            "searchTerm": item.get("title", "")})
                items = json.load(urllib.request.urlopen(urllib.request.Request(
                    f"http://jellyfin:8096/Items?{q}", headers=h), timeout=20)).get("Items", [])
                left = [i for i in items if (i.get("Path") or "").startswith(lib_path)]
                if not left:
                    break
                time.sleep(3)
            for i in left:
                urllib.request.urlopen(urllib.request.Request(f"http://jellyfin:8096/Items/{i['Id']}",
                                                              headers=h, method="DELETE"), timeout=20).read()
            out.append("Jellyfin: quitada")
        except Exception as e:  # noqa: BLE001
            out.append(f"Jellyfin: no se pudo ({e})")
    else:
        out.append("Jellyfin: sin clave, se actualizará en su próximo escaneo")
    # Jellyseerr: borra su ficha (y sus peticiones) para que se pueda volver
    # a pedir y no salga como "disponible".
    key = service_key("jellyseerr/settings.json", "main", "apiKey")
    tmdb = item.get("tmdbId")
    if key and tmdb:
        try:
            h = {"X-Api-Key": key}
            kind = "movie" if app == "radarr" else "tv"
            info = json.load(urllib.request.urlopen(urllib.request.Request(
                f"http://jellyseerr:5055/api/v1/{kind}/{tmdb}", headers=h), timeout=20)).get("mediaInfo") or {}
            if info.get("id"):
                urllib.request.urlopen(urllib.request.Request(f"http://jellyseerr:5055/api/v1/media/{info['id']}",
                                                              headers=h, method="DELETE"), timeout=20).read()
                out.append("Seerr: quitada")
            else:
                out.append("Seerr: no la tenía")
        except Exception as e:  # noqa: BLE001
            out.append(f"Seerr: no se pudo ({e})")
    return "; ".join(out)


def jf_date(s):
    """'2026-09-22T09:23:22.5639085Z' -> epoch (Jellyfin da 7 decimales)."""
    try:
        return calendar.timegm(time.strptime(s[:19], "%Y-%m-%dT%H:%M:%S"))
    except (TypeError, ValueError):
        return None


def watched_list(top):
    """Peliculas vistas y series vistas enteras en Jellyfin hace mas de
    WATCHED_DAYS, por cualquier usuario y sin favoritos de nadie (spec 040).
    Solo lo que tiene X en "lo que mas ocupa" (lo gestiona Radarr/Sonarr):
    la X de la pagina es la misma. None si Jellyfin no responde."""
    key = service_key("jellyseerr/settings.json", "jellyfin", "apiKey")
    if not key:
        return None
    h = {"Authorization": f'MediaBrowser Token="{key}"'}  # Jellyfin 12.2: X-Emby-Token da 401

    def get(path, **q):
        url = f"http://jellyfin:8096/{path}" + (f"?{urllib.parse.urlencode(q)}" if q else "")
        return json.load(urllib.request.urlopen(urllib.request.Request(url, headers=h), timeout=30))

    def folder(path):  # /data/media/movies/X/X.mkv -> ("movies", "X")
        parts = (path or "")[len(MEDIA) + 1:].split("/") if (path or "").startswith(MEDIA + "/") else []
        return tuple(parts[:2]) if len(parts) >= 2 else None

    try:
        seen, favs = {}, set()
        for u in get("Users"):
            uid, name = u["Id"], u["Name"]
            for i in get(f"Users/{uid}/Items", Recursive="true", IncludeItemTypes="Movie,Series",
                         Filters="IsFavorite", Fields="Path").get("Items", []):
                favs.add(folder(i.get("Path")))
            for i in get(f"Users/{uid}/Items", Recursive="true", IncludeItemTypes="Movie,Series",
                         Filters="IsPlayed", Fields="Path").get("Items", []):
                f = folder(i.get("Path"))
                if not f:
                    continue
                when = jf_date(i.get("UserData", {}).get("LastPlayedDate"))
                if i.get("Type") == "Series":  # la serie no tiene fecha: la de su ultimo episodio visto
                    eps = get(f"Users/{uid}/Items", ParentId=i["Id"], Recursive="true", IncludeItemTypes="Episode",
                              Filters="IsPlayed", SortBy="DatePlayed", SortOrder="Descending", Limit="1").get("Items", [])
                    when = jf_date(eps[0].get("UserData", {}).get("LastPlayedDate")) if eps else None
                w = seen.setdefault(f, {"last": 0, "users": []})
                w["last"] = max(w["last"], when or 0)
                w["users"].append(name)
    except Exception as e:  # noqa: BLE001 -- sin la seccion, pero el informe sale
        log(f"Jellyfin no responde para lo ya visto ({e}).")
        return None
    out = []
    cutoff = time.time() - WATCHED_S
    for kind in ("movies", "tv"):
        for row in top.get(kind, []):
            w = seen.get((kind, row["name"]))
            # Sin fecha (visto marcado a mano, sin reproducir) cuenta como antiguo.
            if not row.get("arr") or not w or (kind, row["name"]) in favs or w["last"] > cutoff:
                continue
            out.append({"kind": kind, "name": row["name"], "bytes": row["bytes"], "arr": row["arr"],
                        "last_played": w["last"] or None, "users": sorted(set(w["users"]))})
    out.sort(key=lambda x: -x["bytes"])
    return out


def remove_library_items(items):
    with lock:
        top = (state["report"] or {}).get("top", {})
    known = {(("radarr" if k == "movies" else "sonarr"), row["arr"]["id"])
             for k in ("movies", "tv") for row in top.get(k, []) if row.get("arr")}
    results = []
    for it in items:
        r = {"ok": False}
        results.append(r)
        try:
            key = (it.get("app"), int(it.get("id")))
        except (AttributeError, TypeError, ValueError):
            r["error"] = "petición no válida"
            continue
        if key not in known:
            r["error"] = "no está en la lista"
            continue
        try:
            r.update(remove_library(*key))
            r["ok"] = True
        except Exception as e:  # noqa: BLE001
            r["error"] = str(e)
            log(f"NO quitado de la biblioteca {key}: {e}")
    return results


config_cache = {"at": 0, "files": []}


def config_walk():
    """/config casi no cambia de tamano y es lo lento de recorrer (miles de
    archivos pequenos de metadatos de Jellyfin: ~3 min frente a ~10 s de
    todo /data en esta maquina). Se reutiliza hasta CONFIG_MAX_AGE_S."""
    if not os.path.isdir(CONFIG):
        return []
    if time.time() - config_cache["at"] > CONFIG_MAX_AGE_S:
        t0 = time.time()
        config_cache["files"] = walk_files(CONFIG)
        config_cache["at"] = time.time()
        log(f"/config medido en {time.time() - t0:.0f} s ({len(config_cache['files'])} archivos).")
    return config_cache["files"]


# ---------------------------------------------------------------------------
# Extras (specs 035 y 036): los de las descargas (Featurettes/, Deleted
# Scenes/...) van enlazados dentro de la carpeta de su pelicula o serie,
# p.ej. media/movies/<X>/featurettes/. Aqui solo se PLANIFICA (tambien en
# cada escaneo, para la pagina): los enlaces los hace
# scripts\importar-extras.ps1 en Windows (un hardlink no cruza montajes y
# disk-report no escribe en media/). El boton de la pagina deja
# EXTRAS_FLAG y la tarea de Windows de la spec 030 lanza el script.
# ---------------------------------------------------------------------------
# Subcarpetas que Jellyfin muestra como extras Y que Radarr/Sonarr ignoran
# al escanear (DiskScanService.ExcludedExtrasSubFolderRegex).
EXTRA_KNOWN = {"extras", "behind the scenes", "deleted scenes", "featurettes", "interviews", "other", "scenes",
               "shorts", "trailers"}
# Tambien se reconocen en la descarga, pero van a "extras". No "specials":
# en las series suele ser la temporada 0, que es de Sonarr.
EXTRA_ALSO = {"bonus", "clips"}
EXTRAS_FLAG = os.path.join(os.path.dirname(STATE_FILE), "importar-extras")
EXTRAS_RUNNING = EXTRAS_FLAG + ".en-curso"
EXTRAS_RESULT = os.path.join(os.path.dirname(STATE_FILE), "extras-resultado.json")


def extra_dir(gpath, path):
    """Subcarpeta de extras de la descarga en la que esta `path` (la mas
    cercana), o None si no es un extra."""
    if os.path.splitext(path)[1].lower() not in VIDEO_EXT:
        return None
    dirs = os.path.relpath(path, gpath).split("/")[:-1]
    return next((d for d in reversed(dirs) if d.lower() in EXTRA_KNOWN | EXTRA_ALSO), None)


def extras_plan(media_files, torrent_files, cat_dirs):
    """(items, unknown): extras sin enlazar por pelicula/serie, y descargas
    con extras de dueno desconocido. Dueno = la carpeta de la biblioteca
    donde esta enlazado el resto de la descarga (por inodo)."""
    own = {}
    for kind in ("movies", "tv"):
        root = os.path.join(MEDIA, kind) + "/"
        for p, st in media_files:
            if p.startswith(root) and st.st_nlink > 1:
                own[st.st_ino] = root + p[len(root):].split("/", 1)[0]
    files = [x for x in torrent_files if x[0][len(TORRENTS) + 1:].split("/", 1)[0] not in INCOMPLETE_DIRS]
    items, unknown = [], []
    for gpath, gfiles in sorted(torrent_groups(files, cat_dirs).items()):
        extras = sorted((p, st, extra_dir(gpath, p)) for p, st in gfiles if extra_dir(gpath, p))
        if not extras:
            continue
        name = os.path.relpath(gpath, TORRENTS)
        who = {own[st.st_ino] for p, st in gfiles if st.st_ino in own and not extra_dir(gpath, p)}
        if len(who) != 1:
            unknown.append({"download": name, "reason": "no está en la biblioteca" if not who
                            else "está enlazada a varias cosas de la biblioteca"})
            continue
        (folder,) = who
        links, taken = [], {}
        for p, st, d in extras:
            if st.st_nlink > 1:
                continue  # ya enlazado (de una ejecucion anterior)
            dest_dir = os.path.join(folder, d.lower() if d.lower() in EXTRA_KNOWN else "extras")
            if dest_dir not in taken:
                taken[dest_dir] = {n.lower() for n in os.listdir(dest_dir)} if os.path.isdir(dest_dir) else set()
            base = os.path.basename(p)
            if base.lower() in taken[dest_dir]:
                continue
            taken[dest_dir].add(base.lower())
            links.append({"src": p, "dest": os.path.join(dest_dir, base), "bytes": st.st_size})
        if links:
            items.append({"owner": os.path.basename(folder), "folder": folder, "download": name, "links": links})
    return items, unknown


# Resultados posteriores a esto -> reescanear (los de antes de arrancar no).
extras_seen = {"at": time.time()}


def extras_status():
    """Para la pagina: pedido (esperando a la tarea de Windows), en curso y
    ultimo resultado. Un resultado nuevo lanza un escaneo, para que la
    fila desaparezca de Pendiente."""
    def mtime(p):
        try:
            return int(os.path.getmtime(p))
        except OSError:
            return None
    result = None
    try:
        with open(EXTRAS_RESULT, encoding="utf-8-sig") as f:
            result = json.load(f)
    except (OSError, ValueError):
        pass
    if result and result.get("at", 0) > extras_seen["at"]:
        extras_seen["at"] = result["at"]
        wake.set()
    return {"requested_at": mtime(EXTRAS_FLAG), "running_since": mtime(EXTRAS_RUNNING), "result": result}


def request_extras_import():
    if os.path.exists(EXTRAS_FLAG) or os.path.exists(EXTRAS_RUNNING):
        return {"ok": True, "message": "Ya estaba pedido."}
    try:
        with open(EXTRAS_FLAG, "w", encoding="utf-8") as f:
            f.write(str(int(time.time())))
    except OSError as e:
        return {"ok": False, "error": f"No se ha podido pedir: {e}"}
    log("Importar extras: pedido (aviso para la tarea de Windows).")
    return {"ok": True}


# ---------------------------------------------------------------------------
# Subtitulos que Bazarr cree tener y no estan (spec 043). Caso real: Gravity
# Falls T1 (history/028), pistas incrustadas de un fichero anterior; como el
# perfil parecia cumplido, Bazarr no buscaba otros. Lo bueno lo sabe
# Sonarr/Radarr (mediaInfo.subtitles) y el disco. Solo cuenta si afecta a un
# idioma del perfil (si no, no cambia nada). El boton usa la descarga manual
# de Bazarr, que busca sin mirar su missing_subtitles.
# ---------------------------------------------------------------------------
BAZARR = "http://bazarr:6767"
# Codigos de Bazarr/ISO 639-2/T -> los de Sonarr/Radarr (639-2/B), y las
# variantes de Bazarr (spl = espanol latino, zht = chino tradicional...).
LANG3 = {"deu": "ger", "fra": "fre", "nld": "dut", "ces": "cze", "zho": "chi", "zht": "chi", "zhs": "chi",
         "ron": "rum", "slk": "slo", "ell": "gre", "isl": "ice", "msa": "may", "mkd": "mac", "fas": "per",
         "sqi": "alb", "hye": "arm", "eus": "baq", "mya": "bur", "kat": "geo", "cym": "wel", "bod": "tib",
         "spl": "spa", "pob": "por", "nob": "nor", "nno": "nor"}
subs_job = {"running": False, "done": 0, "total": 0, "ok": 0, "at": None, "message": ""}


def lang3(c):
    c = (c or "").lower()
    return LANG3.get(c, c)


def bazarr_key():
    try:
        with open(os.path.join(CONFIG, "bazarr", "config", "config.yaml"), encoding="utf-8") as f:
            m = re.search(r"^auth:\s*$.*?^\s+apikey:\s*['\"]?([^\s'\"]+)", f.read(), re.M | re.S)
        return m.group(1) if m else None
    except OSError:
        return None


def bazarr_api(path, method="GET", **q):
    url = f"{BAZARR}/api/{path}" + (f"?{urllib.parse.urlencode(q, doseq=True)}" if q else "")
    req = urllib.request.Request(url, method=method, data=b"" if method != "GET" else None,
                                 headers={"X-API-KEY": bazarr_key() or ""})
    with urllib.request.urlopen(req, timeout=180) as r:
        body = r.read()
    return json.loads(body) if body else None


def phantom_langs(subs, real, wanted):
    """Idiomas del perfil (code2) que Bazarr da por cumplidos solo con
    subtitulos que no estan: externos sin fichero, o incrustados que
    Sonarr/Radarr no ven en el video. real = codigos de mediaInfo, o None
    si Sonarr/Radarr no lo han analizado (entonces no se juzga)."""
    out = []
    for code2 in wanted:
        entries = [s for s in subs if s.get("code2") == code2]
        if entries and not any(os.path.exists(s["path"]) if s.get("path")
                               else real is None or lang3(s.get("code3")) in real for s in entries):
            out.append(code2)
    return out


def subtitle_audit():
    """Lista para "Pendiente": series (con sus episodios) y peliculas con
    subtitulos fantasma. None si Bazarr no responde."""
    if not bazarr_key():
        return None

    def real_of(media_info):
        if not media_info or "subtitles" not in media_info:
            return None
        return {lang3(x) for x in re.split(r"[/,\s]+", media_info.get("subtitles") or "") if x}

    try:
        profiles = {p["profileId"]: [(i["language"], i.get("hi") == "True", i.get("forced") == "True")
                                     for i in p.get("items", [])]
                    for p in bazarr_api("system/languages/profiles")}
        out = []
        for s in bazarr_api("series").get("data", []):
            prof = profiles.get(s.get("profileId"))
            if not prof:
                continue
            files = {f["path"]: f for f in arr_get("sonarr", f"episodefile?seriesId={s['sonarrSeriesId']}") or []}
            eps = []
            for e in bazarr_api("episodes", **{"seriesid[]": s["sonarrSeriesId"]}).get("data", []):
                f = files.get(e.get("path"))
                if not f:
                    continue
                bad = phantom_langs(e.get("subtitles") or [], real_of(f.get("mediaInfo")), [p[0] for p in prof])
                if bad:
                    eps.append({"id": e["sonarrEpisodeId"], "season": e.get("season"), "episode": e.get("episode"),
                                "langs": bad})
            if eps:
                eps.sort(key=lambda x: (x["season"] or 0, x["episode"] or 0))
                out.append({"kind": "tv", "id": s["sonarrSeriesId"], "title": s.get("title"),
                            "profile": s.get("profileId"), "episodes": eps,
                            "langs": sorted({l for x in eps for l in x["langs"]})})
        movies = {(m.get("movieFile") or {}).get("path"): m for m in arr_get("radarr", "movie") or []}
        for m in bazarr_api("movies").get("data", []):
            rm, prof = movies.get(m.get("path")), profiles.get(m.get("profileId"))
            if not rm or not prof:
                continue
            bad = phantom_langs(m.get("subtitles") or [], real_of(rm["movieFile"].get("mediaInfo")), [p[0] for p in prof])
            if bad:
                out.append({"kind": "movies", "id": m["radarrId"], "title": m.get("title"), "year": rm.get("year"),
                            "profile": m.get("profileId"), "langs": bad})
        subs_job["profiles"] = profiles  # para el boton: hi/forced de cada idioma
        return out
    except Exception as e:  # noqa: BLE001 -- sin la seccion, pero el informe sale
        log(f"Bazarr no responde para la revision de subtitulos ({e}).")
        return None


def search_subtitles(items):
    """Lanza en segundo plano la descarga manual de Bazarr para lo pedido
    (solo lo que esta en la ultima lista)."""
    with lock:
        current = {(x["kind"], x["id"]): x for x in (state["report"] or {}).get("subtitles") or []}
    todo = []
    for it in items:
        try:
            x = current.get((it.get("kind"), int(it.get("id"))))
        except (AttributeError, TypeError, ValueError):
            x = None
        if not x:
            continue
        prof = {p[0]: p for p in subs_job.get("profiles", {}).get(x.get("profile"), [])}
        for e in x.get("episodes") or [None]:
            for code2 in (e["langs"] if e else x["langs"]):
                _, hi, forced = prof.get(code2, (code2, False, False))
                q = {"language": code2, "hi": str(hi).lower(), "forced": str(forced).lower()}
                todo.append(("episodes/subtitles", {**q, "seriesid": x["id"], "episodeid": e["id"]}) if e
                            else ("movies/subtitles", {**q, "radarrid": x["id"]}))
    if not todo:
        return {"ok": False, "error": "No está en la lista (vuelve a cargar la página)."}
    if subs_job["running"]:
        return {"ok": False, "error": "Ya hay una búsqueda en curso."}
    subs_job.update(running=True, done=0, total=len(todo), ok=0, at=int(time.time()), message="")

    def run():
        for path, q in todo:
            try:
                bazarr_api(path, method="PATCH", **q)
                subs_job["ok"] += 1
            except Exception as e:  # noqa: BLE001
                log(f"Bazarr: no se pudo buscar {path} {q} ({e})")
            subs_job["done"] += 1
        subs_job.update(running=False, at=int(time.time()),
                        message=f"Pedidas a Bazarr {subs_job['ok']} de {subs_job['total']}: las descarga en segundo plano "
                                "(unos minutos). Si no aparecen, puede que se haya acabado la cuota diaria de OpenSubtitles.")
        log(f"Subtitulos: {subs_job['message']}")
        # Bazarr descarga en segundo plano (comprobado: el PATCH vuelve en
        # 2 s y el fichero llega despues). Re-escanear un poco mas tarde.
        time.sleep(90)
        wake.set()
    threading.Thread(target=run, daemon=True).start()
    log(f"Subtitulos: buscando {len(todo)} en Bazarr.")
    return {"ok": True}


# ---------------------------------------------------------------------------
# Actualizaciones (spec 042): las busca y las aplica scripts\actualizaciones.ps1
# en Windows (nada aqui toca Docker). Mismo mecanismo que los extras: un aviso
# en el estado, que recoge la tarea de Windows de cada minuto.
# ---------------------------------------------------------------------------
UPDATES_CHECK = os.path.join(os.path.dirname(STATE_FILE), "buscar-actualizaciones")
UPDATES_APPLY = os.path.join(os.path.dirname(STATE_FILE), "actualizar")
UPDATES_RESULT = os.path.join(os.path.dirname(STATE_FILE), "actualizaciones.json")
UPDATES_EVERY_S = 24 * 3600


def file_mtime(p):
    try:
        return int(os.path.getmtime(p))
    except OSError:
        return None


def updates_status():
    result = None
    try:
        with open(UPDATES_RESULT, encoding="utf-8-sig") as f:
            result = json.load(f)
    except (OSError, ValueError):
        pass
    return {"check_requested_at": file_mtime(UPDATES_CHECK), "check_running_since": file_mtime(UPDATES_CHECK + ".en-curso"),
            "apply_requested_at": file_mtime(UPDATES_APPLY), "apply_running_since": file_mtime(UPDATES_APPLY + ".en-curso"),
            "result": result}


def request_updates(apply):
    """Deja el aviso para la tarea de Windows. Actualizar tiene prioridad:
    el script busca otra vez al terminar."""
    s = updates_status()
    if s["apply_requested_at"] or s["apply_running_since"] or (not apply and (s["check_requested_at"] or s["check_running_since"])):
        return {"ok": True, "message": "Ya estaba pedido."}
    try:
        with open(UPDATES_APPLY if apply else UPDATES_CHECK, "w", encoding="utf-8") as f:
            f.write(str(int(time.time())))
    except OSError as e:
        return {"ok": False, "error": f"No se ha podido pedir: {e}"}
    log(f"Actualizaciones: {'actualizar' if apply else 'buscar'} (aviso para la tarea de Windows).")
    return {"ok": True}


# ---------------------------------------------------------------------------
# Actualizar MediaCenter mismo (spec 051): la version instalada viene de
# version.env (MC_VERSION; una copia de git no lo tiene y no se le ofrece
# nada). Una vez al dia se mira la ultima etiqueta del repo publico y sus
# NOVEDADES.md; el boton deja un aviso con la version que recoge la tarea de
# Windows (scripts\actualizar-mediacenter.ps1). Aqui no se toca nada.
# ---------------------------------------------------------------------------
MC_VERSION = os.environ.get("MC_VERSION", "").strip()
APP_REPO = "DiegoSMR/MediaCenter-App-Download"
APP_FLAG = os.path.join(os.path.dirname(STATE_FILE), "actualizar-mediacenter")
APP_RESULT = os.path.join(os.path.dirname(STATE_FILE), "mediacenter-actualizacion.json")
APP_LATEST = os.path.join(os.path.dirname(STATE_FILE), "mediacenter-ultima.json")


def version_key(v):
    try:
        return tuple(int(x) for x in v.lstrip("v").split("."))
    except (ValueError, AttributeError):
        return ()


def read_json(path):
    try:
        with open(path, encoding="utf-8-sig") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def app_check_latest():
    """Ultima version publicada y sus novedades (API publica de GitHub)."""
    req = urllib.request.Request(f"https://api.github.com/repos/{APP_REPO}/tags?per_page=100",
                                 headers={"User-Agent": "MediaCenter", "Accept": "application/vnd.github+json"})
    tags = [t.get("name", "") for t in json.load(urllib.request.urlopen(req, timeout=20))]
    tags = [t for t in tags if version_key(t)]
    latest = max(tags, key=version_key).lstrip("v") if tags else None
    notes = ""
    if latest:
        try:
            raw = f"https://raw.githubusercontent.com/{APP_REPO}/v{latest}/NOVEDADES.md"
            notes = urllib.request.urlopen(urllib.request.Request(raw, headers={"User-Agent": "MediaCenter"}),
                                           timeout=20).read().decode("utf-8", "replace")[:4000]
        except Exception:  # noqa: BLE001 -- sin novedades no pasa nada
            pass
    out = {"checked_at": int(time.time()), "latest": latest, "notes": notes}
    tmp = APP_LATEST + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False)
    os.replace(tmp, APP_LATEST)
    log(f"MediaCenter: instalada {MC_VERSION or '?'}, ultima publicada {latest or '?'}.")
    return out


def app_status():
    latest = read_json(APP_LATEST) or {}
    avail = bool(MC_VERSION and MC_VERSION != "dev" and latest.get("latest")
                 and version_key(latest["latest"]) > version_key(MC_VERSION))
    return {"version": MC_VERSION or None, "latest": latest, "available": avail,
            "requested_at": file_mtime(APP_FLAG), "running_since": file_mtime(APP_FLAG + ".en-curso"),
            "result": read_json(APP_RESULT)}


def request_app_update():
    s = app_status()
    if not QBT_NATIVO:
        return {"ok": False, "error": "Solo con qBittorrent en Windows (hace falta su tarea programada)."}
    if s["requested_at"] or s["running_since"]:
        return {"ok": True, "message": "Ya estaba pedido."}
    if not s["available"]:
        return {"ok": False, "error": "No hay una versión nueva de MediaCenter."}
    try:
        with open(APP_FLAG, "w", encoding="utf-8") as f:
            f.write(s["latest"]["latest"])
    except OSError as e:
        return {"ok": False, "error": f"No se ha podido pedir: {e}"}
    log(f"MediaCenter: actualizar a {s['latest']['latest']} (aviso para la tarea de Windows).")
    return {"ok": True}


def updates_daily():
    """Una busqueda al dia, desde el bucle del escaneo. Solo donde hay tarea
    de Windows que la recoja (qBittorrent nativo, como el resto de avisos)."""
    if not QBT_NATIVO:
        return
    r = updates_status()["result"] or {}
    if time.time() - (r.get("checked_at") or 0) > UPDATES_EVERY_S:
        request_updates(False)
    # MediaCenter mismo (spec 051): solo si sabe su version (no en git).
    if MC_VERSION and MC_VERSION != "dev":
        if time.time() - ((read_json(APP_LATEST) or {}).get("checked_at") or 0) > UPDATES_EVERY_S:
            try:
                app_check_latest()
            except Exception as e:  # noqa: BLE001
                log(f"MediaCenter: no se ha podido mirar si hay version nueva ({e})")


# ---------------------------------------------------------------------------
# Comprobacion de la instalacion (spec 049): verify.py mira el resultado en
# cada app (no cambia nada). Al arrancar (cuando bootstrap ya ha terminado),
# una vez al dia y con el boton "Comprobar ahora".
# ---------------------------------------------------------------------------
VERIFY_RESULT = os.path.join(os.path.dirname(STATE_FILE), "verificacion.json")
VERIFY_FIRST_S = 600
VERIFY_EVERY_S = 24 * 3600
verify_job = {"running": False}


def verify_status():
    result = None
    try:
        with open(VERIFY_RESULT, encoding="utf-8") as f:
            result = json.load(f)
    except (OSError, ValueError):
        pass
    return {"running": verify_job["running"], "result": result}


def run_verify():
    """En segundo plano; una a la vez."""
    with lock:
        if verify_job["running"]:
            return {"ok": True, "message": "Ya se está comprobando."}
        verify_job["running"] = True

    def work():
        try:
            r = verify.run()
            tmp = VERIFY_RESULT + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(r, f, ensure_ascii=False)
            os.replace(tmp, VERIFY_RESULT)
            s = r["summary"]
            log(f"Comprobacion: {s['ok']} bien, {s['aviso']} avisos, {s['fallo']} fallos.")
            for i in r["checks"]:
                if i["level"] != "ok":
                    log(f"  {i['level'].upper()} {i['app']}: {i['name']} -- {i['detail']}")
        except Exception as e:  # noqa: BLE001
            log(f"Comprobacion: no se ha podido hacer ({e})")
        finally:
            verify_job["running"] = False
    threading.Thread(target=work, daemon=True).start()
    return {"ok": True}


def verifier():
    time.sleep(VERIFY_FIRST_S)
    while True:
        r = verify_status()["result"] or {}
        if time.time() - (r.get("checked_at") or 0) > VERIFY_EVERY_S - 60 or not r:
            run_verify()
        time.sleep(3600)


# Bloqueos de LaLiga (spec 050): cada 10 min, la lista de hayahora.futbol y
# si The Pirate Bay responde (verify.football_status). Solo lee.
FOOTBALL_EVERY_S = 600
football = {"status": None}


def football_watch():
    while True:
        try:
            s = verify.football_status()
            prev = (football["status"] or {}).get("active", False)
            football["status"] = s
            if s["active"] != prev:  # una linea al empezar y otra al terminar
                log(f"Bloqueos de LaLiga: {'ACTIVOS, The Pirate Bay no responde' if s['active'] else 'terminados'}"
                    f" ({s['blocked_ips']} IPs bloqueadas).")
        except Exception as e:  # noqa: BLE001
            log(f"Bloqueos de LaLiga: no se ha podido mirar ({e})")
        time.sleep(FOOTBALL_EVERY_S)


def scan():
    t0 = time.time()
    now = time.time()
    torrents, cat_paths = qbt_torrents()
    cat_dirs = set(CATEGORY_DIRS)
    for cp in cat_paths:
        local = to_local(cp)
        if os.path.dirname(local) == TORRENTS:
            cat_dirs.add(os.path.basename(local))

    data_files = walk_files(DATA)
    t_data = time.time() - t0
    config_files = config_walk()

    # Bytes reales ocupados por /data: un archivo con hardlink en torrents/
    # y en media/ cuenta una sola vez.
    seen, unique = set(), 0
    for _, st in data_files:
        k = (st.st_dev, st.st_ino)
        if k not in seen:
            seen.add(k)
            unique += st.st_size

    def under(top):
        pre = top.rstrip("/") + "/"
        return [x for x in data_files if x[0].startswith(pre)]

    torrent_files = under(TORRENTS)
    incomplete_files = [x for x in torrent_files
                        if x[0][len(TORRENTS) + 1:].split("/", 1)[0] in INCOMPLETE_DIRS]

    ghosts = []
    for path, gfiles in torrent_groups(torrent_files, cat_dirs).items():
        g = classify(path, gfiles, torrents, now)
        if g:
            g["blocked"] = block_reason(g, include_unknown=True)
            ghosts.append(g)
    ghosts.sort(key=lambda g: -g["ghost_bytes"])
    annotate_imports(ghosts)
    # Extras por poner (spec 036). Si lo que sobra de una descarga son justo
    # sus extras, no se repite como "Solo una parte".
    extras, extras_unknown = extras_plan(under(MEDIA), torrent_files, cat_dirs)
    planned = {l["src"] for i in extras for l in i["links"]}
    for g in ghosts:
        g["extras_pending"] = all(
            (os.path.join(g["path"], f["name"]) if os.path.isdir(g["path"]) else g["path"]) in planned
            for f in g["files"]) and bool(g["files"])

    # Descargas a medias que qBittorrent ya no conoce (torrent borrado sin
    # sus archivos, o qBittorrent reinstalado): basura que no avanza.
    leftovers = []
    for d in INCOMPLETE_DIRS:
        top = os.path.join(TORRENTS, d)
        for item in child_sizes(top, incomplete_files):
            p = os.path.join(top, item["name"])
            t = torrent_for(p, torrents)
            leftovers.append({**item, "path": p, "qbt": torrent_info(t),
                              "orphan": torrents is not None and t is None})

    torrents_total = size_of(torrent_files)
    incomplete_total = size_of(incomplete_files)
    ghost_total = sum(g["ghost_bytes"] for g in ghosts)
    # Todo lo de torrents/ fuera de incomplete/ con contador >1: comparte
    # espacio con la biblioteca, borrarlo no liberaria nada.
    linked_total = sum(st.st_size for p, st in torrent_files if st.st_nlink > 1)

    disk = disk_usage(DATA)
    config_total = size_of(config_files)
    same_disk = os.path.isdir(CONFIG) and disk_usage(CONFIG)["total"] == disk["total"]
    other = disk["used"] - unique - (config_total if same_disk else 0)

    folders = [
        {"key": "movies", "label": "Biblioteca · películas", "bytes": size_of(under(os.path.join(MEDIA, "movies")))},
        {"key": "tv", "label": "Biblioteca · series", "bytes": size_of(under(os.path.join(MEDIA, "tv")))},
    ]
    for c in children(MEDIA):
        if c.is_dir() and c.name not in ("movies", "tv"):
            folders.append({"key": f"media-{c.name}", "label": f"Biblioteca · {c.name}",
                            "bytes": size_of(under(c.path))})
    folders += [
        {"key": "torrents", "label": "Descargas completadas (torrents)", "bytes": torrents_total - incomplete_total,
         "note": f"{fmt(linked_total)} compartido con la biblioteca (no ocupa extra) · {fmt(ghost_total)} fantasma"},
        {"key": "incomplete", "label": "Descargas a medias (incomplete)", "bytes": incomplete_total},
    ]
    for c in children(DATA):
        if c.is_dir() and c.name not in ("torrents", "media"):
            label = "Descargas propias (descargas, sin categoría)" if c.name == "descargas" else c.name
            folders.append({"key": f"data-{c.name}", "label": label, "bytes": size_of(under(c.path))})
    transcodes = os.path.join(CONFIG, "jellyfin", "cache", "transcodes")
    folders.append({"key": "config", "label": "Configuración de las apps", "bytes": config_total,
                    "note": f"Caché de transcodificación de Jellyfin: "
                            f"{fmt(size_of([x for x in config_files if x[0].startswith(transcodes + '/')]))}"})

    report = {
        "generated": int(time.time()),
        "scan_seconds": round(time.time() - t0, 1),
        "interval_hours": INTERVAL_S / 3600,
        "warn_percent": WARN_PERCENT,
        "recent_hours": RECENT_S / 3600,
        "qbt_ok": torrents is not None,
        "config_measured": int(config_cache["at"]) or None,
        "disk": {**disk, "data_unique": unique, "config": config_total if same_disk else None,
                 "other": max(other, 0)},
        "folders": folders,
        "ghosts": ghosts,
        "ghost_total": ghost_total,
        "leftovers": leftovers,
        "extras": [{"owner": i["owner"], "download": i["download"], "count": len(i["links"]),
                    "bytes": sum(l["bytes"] for l in i["links"])} for i in extras],
        "extras_unknown": extras_unknown,
        "top": {
            "movies": child_sizes(os.path.join(MEDIA, "movies"), under(os.path.join(MEDIA, "movies"))),
            "tv": child_sizes(os.path.join(MEDIA, "tv"), under(os.path.join(MEDIA, "tv"))),
            "config": child_sizes(CONFIG, config_files),
        },
    }
    lib = library_index()
    for key, app in (("movies", "radarr"), ("tv", "sonarr")):
        for row in report["top"][key]:
            row["arr"] = lib.get(app, {}).get(row["name"])
    report["watched"] = watched_list(report["top"])
    report["watched_days"] = WATCHED_S / 86400
    report["subtitles"] = subtitle_audit()
    log(f"Escaneo completado en {report['scan_seconds']} s (/data: {t_data:.0f} s): {len(data_files)} archivos en /data, "
        f"{len(ghosts)} fantasmas ({fmt(ghost_total)}), libre {fmt(disk['free'])}.")
    return report


def fmt(n):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1024 or unit == "TB":
            return f"{n:.1f} {unit}" if unit != "B" else f"{n} B"
        n /= 1024


# ---------------------------------------------------------------------------
# Bucle de escaneo + servidor
# ---------------------------------------------------------------------------
state = {"report": None, "scanning": False, "error": None}
lock = threading.Lock()
wake = threading.Event()


def scanner():
    while True:
        with lock:
            state["scanning"] = True
        try:
            r = scan()
            if AUTO_IMPORT:
                with delete_lock:  # nunca a la vez que un borrado/importacion de la pagina
                    done = auto_import(r)
                if done:
                    r = scan()  # que la pagina ya lo refleje
            with lock:
                state["report"], state["error"] = r, None
        except Exception as e:  # noqa: BLE001 -- se muestra en la pagina
            log(f"ERROR en el escaneo: {e!r}")
            with lock:
                state["error"] = repr(e)
        finally:
            with lock:
                state["scanning"] = False
        updates_daily()
        wake.wait(INTERVAL_S)
        wake.clear()


delete_lock = threading.Lock()


def stop_searching(g):
    """Radarr/Sonarr dejan de vigilar lo que esta descarga iba a traer (spec
    033), para que no lo vuelvan a descargar al borrarla. Si no se sabe que
    es, error: mejor no borrar que borrar y que vuelva."""
    a = g["arr"]
    if a["app"] == "radarr":
        arr_put("radarr", "movie/editor", {"movieIds": [a["id"]], "monitored": False})
        return f"Radarr ya no busca {a.get('title')}."
    # Los episodios que faltan, como en sonarr_files; si /parse no entiende
    # los nombres, los del historial de la descarga (como arr_lookup).
    ids = set()
    for f in g["files"]:
        r = arr_get("sonarr", "parse?" + urllib.parse.urlencode({"title": os.path.basename(f["name"])})) or {}
        ids |= {e["id"] for e in r.get("episodes") or [] if e.get("monitored") and not e.get("hasFile")}
    if not ids and g.get("qbt"):
        hist = arr_get("sonarr", f"history?pageSize=100&downloadId={g['qbt']['hash'].upper()}") or {}
        ep_ids = sorted({x["episodeId"] for x in hist.get("records", []) if x.get("episodeId")})
        if ep_ids:
            eps = arr_get("sonarr", "episode?" + urllib.parse.urlencode([("episodeIds", i) for i in ep_ids])) or []
            ids = {e["id"] for e in eps if e.get("monitored") and not e.get("hasFile")}
    if not ids:
        raise RuntimeError("no se sabe qué episodios son, así que no se borra (Sonarr la volvería a descargar)")
    arr_put("sonarr", "episode/monitor", {"episodeIds": sorted(ids), "monitored": False})
    return f"Sonarr ya no busca {len(ids)} episodio(s) de {a.get('title')}."


def delete_paths(paths, allow_risky=False):
    """Borra las descargas pedidas desde la pagina, una a una. Solo acepta
    rutas que el ultimo escaneo listo como fantasma, y aun asi las vuelve a
    analizar en el momento. allow_risky (spec 033): la pagina ya aviso del
    riesgo al confirmar -> se ignora block_reason; si Radarr/Sonarr aun la
    esperaban, primero dejan de buscarla."""
    with lock:
        known = {g["path"] for g in (state["report"] or {}).get("ghosts", [])}
    results = []
    with delete_lock:
        qbt = None
        for p in paths:
            r = {"path": p, "ok": False}
            results.append(r)
            if not isinstance(p, str) or p not in known:
                r["error"] = "no está en la lista de fantasmas"
                continue
            try:
                g = fresh_ghost(p)
                if g is None:
                    r["error"] = "ya no es un fantasma (o ya no existe)"
                    continue
                reason = block_reason(g, include_unknown=True)
                if reason and not allow_risky:
                    r["error"] = reason
                    continue
                if g.get("qbt") and qbt is None:
                    qbt = Qbt()  # si falla, no se borra: quedaria un torrent roto
                if (g.get("arr") or {}).get("verdict") == "missing":
                    r["unmonitored"] = stop_searching(g)
                    log(f"Dejar de buscar antes de borrar {p}: {r['unmonitored']}")
                r["bytes"] = delete_ghost(g, qbt)
                r["ok"] = True
                log(f"BORRADO desde la pagina: {p} ({fmt(r['bytes'])})")
            except Exception as e:  # noqa: BLE001 -- se informa y se sigue
                r["error"] = str(e) + (f" (aun así, {r['unmonitored']})" if r.get("unmonitored") else "")
                log(f"NO borrado {p}: {r['error']}")
    return results


# ---------------------------------------------------------------------------
# Parar / reanudar descargas (spec 028). Para TODO lo que este en marcha,
# tambien lo que comparte (lo pidio el usuario: como el "parar" de
# qBittorrent). Parar lo que comparte no hace que Radarr/Sonarr lo borren
# con Remove Completed (spec 023): exigen ademas el limite de 72 h, y ese
# tiempo no corre con el torrent parado (limites de ratio e inactividad
# desactivados, comprobado 2026-09-29). Cada torrent parado lleva el tag
# PAUSE_TAG (y FORCED_TAG si estaba en "forzar inicio") y "reanudar" solo
# arranca esos: nunca uno que se paro a mano en qBittorrent. El estado va
# en STATE_FILE (sobrevive a reinicios).
# ---------------------------------------------------------------------------
FORCED_TAG = "mediacenter-pausa-forzado"
# Ya parado, o en un estado que es mejor no interrumpir.
NOT_STOPPABLE = {"stoppedUP", "stoppedDL", "pausedUP", "pausedDL", "error", "missingFiles", "moving"}
dl_lock = threading.Lock()


def load_dl_state():
    try:
        with open(STATE_FILE, encoding="utf-8") as f:
            s = json.load(f)
        if isinstance(s, dict) and "paused" in s:
            return s
    except (OSError, ValueError):
        pass
    return {"paused": False}


def save_dl_state(s):
    """Sin poder guardarlo, la pausa sigue en memoria: no se deshace lo ya
    hecho en qBittorrent por eso."""
    try:
        os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
        tmp = STATE_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(s, f)
        os.replace(tmp, STATE_FILE)
    except OSError as e:
        log(f"AVISO: no se puede guardar {STATE_FILE} ({e}); el estado de la pausa no sobrevivirá a un reinicio.")


dl_state = load_dl_state()
guard_info = {"error": None}


def stop_downloads(qbt):
    """Para (y marca) todo lo que este en marcha. Devuelve cuantos."""
    running = [t for t in qbt.torrents() if t.get("state") not in NOT_STOPPABLE]
    hashes = [t["hash"] for t in running]
    forced = [t["hash"] for t in running if t.get("force_start")]
    if hashes:
        # Primero los tags: si el stop fallase a medias, "reanudar" solo
        # arrancaria algo que ya estaba en marcha.
        qbt.call("addTags", hashes, tags=PAUSE_TAG)
        if forced:
            qbt.call("addTags", forced, tags=FORCED_TAG)
        qbt.call("stop", hashes)
    return len(hashes)


def start_downloads(qbt):
    hashes = [t["hash"] for t in qbt.torrents(tag=PAUSE_TAG)]
    forced = [t["hash"] for t in qbt.torrents(tag=FORCED_TAG)]
    if hashes:
        qbt.call("start", hashes)
        if forced:  # vuelven a "forzar inicio", como estaban
            qbt.call("setForceStart", forced, value="true")
        qbt.call("removeTags", hashes, tags=f"{PAUSE_TAG},{FORCED_TAG}")
    return len(hashes)


def set_paused(paused, reason):
    """Llamar con dl_lock cogido. Devuelve el resultado para la pagina."""
    qbt = Qbt()
    if paused:
        n = stop_downloads(qbt)
        dl_state.clear()
        dl_state.update({"paused": True, "reason": reason, "since": int(time.time())})
    else:
        n = start_downloads(qbt)
        dl_state.clear()
        dl_state.update({"paused": False})
    save_dl_state(dl_state)
    log(f"Descargas {'PARADAS' if paused else 'REANUDADAS'} ({reason}): {n} torrent(s).")
    return {"ok": True, "count": n}


# Abrir qBittorrent desde el panel (spec 030). Solo con qBittorrent nativo
# en Windows (spec 013): desde Docker no se puede abrir un programa de
# Windows, asi que "Reanudar" con qBittorrent cerrado deja este aviso y la
# tarea de Windows "MediaCenter qBittorrent (panel)" (scripts\qbt-abrir.cmd,
# cada minuto) lanza qBittorrent si lo ve. Solo disk-report lo borra, cuando
# qBittorrent ya responde.
QBT_NATIVO = bool(HOST_DATA_ROOT) and HOST_DATA_ROOT != DATA
OPEN_FLAG = os.path.join(os.path.dirname(STATE_FILE), "abrir-qbittorrent")


def qbt_up():
    """Responde o no, sin login: cualquier respuesta HTTP (403 sin sesion)
    es que esta abierto; un error de conexion, que esta cerrado."""
    try:
        urllib.request.urlopen(f"{QBT_URL}/api/v2/app/version", timeout=3).read()
        return True
    except urllib.error.HTTPError:
        return True
    except Exception:  # noqa: BLE001 -- conexion rechazada, timeout...
        return False


def open_requested():
    return os.path.exists(OPEN_FLAG)


def downloads_action(paused):
    with dl_lock:
        free = disk_usage(DATA)["free"]
        if not paused and free < MIN_FREE:
            return {"ok": False, "error": f"Quedan {fmt_es(free)} libres y el mínimo es {fmt_es(MIN_FREE)}: se volverían a "
                                          f"parar solas en un minuto. Libera espacio primero."}
        if QBT_NATIVO and not qbt_up():
            if paused:
                return {"ok": True, "count": 0, "message": "qBittorrent está cerrado: no está descargando nada."}
            try:
                with open(OPEN_FLAG, "w", encoding="utf-8") as f:
                    f.write(str(int(time.time())))
            except OSError as e:
                return {"ok": False, "error": f"No se ha podido pedir que se abra qBittorrent: {e}"}
            log("qBittorrent cerrado: pedido que se abra (aviso para la tarea de Windows).")
            return {"ok": True, "count": 0, "opening": True,
                    "message": "Abriendo qBittorrent en Windows (puede tardar hasta un minuto)…"}
        try:
            return set_paused(paused, "manual")
        except Exception as e:  # noqa: BLE001 -- se informa en la pagina
            return {"ok": False, "error": f"qBittorrent no responde: {e}"}


def downloads_status():
    free = disk_usage(DATA)["free"]
    with dl_lock:
        s = dict(dl_state)
    closed = QBT_NATIVO and not qbt_up()
    return {**s, "free": free, "min_free": MIN_FREE, "resume_at": MIN_FREE + RESUME_MARGIN,
            "closed": closed, "opening": closed and open_requested(),
            "error": None if closed else guard_info["error"]}


def guard_tick():
    if QBT_NATIVO:
        if not qbt_up():
            return  # cerrado: nada que parar ni reanudar (y no es un error)
        if open_requested():
            # Se abrio desde el panel: reanudar lo que paro el boton, si algo.
            os.remove(OPEN_FLAG)
            with dl_lock:
                set_paused(False, "abierto desde el panel")
    free = disk_usage(DATA)["free"]
    with dl_lock:
        if not dl_state["paused"]:
            if free < MIN_FREE:
                log(f"Quedan {fmt(free)} libres (mínimo {fmt(MIN_FREE)}): parando descargas.")
                set_paused(True, "auto")
        elif dl_state.get("reason") == "auto" and free > MIN_FREE + RESUME_MARGIN:
            set_paused(False, "auto")
        else:
            # En pausa: lo que Radarr/Sonarr hayan anadido desde entonces
            # tambien se para.
            n = stop_downloads(Qbt())
            if n:
                log(f"En pausa: parados {n} torrent(s) nuevo(s).")


def guard():
    while True:
        try:
            guard_tick()
            guard_info["error"] = None
        except Exception as e:  # noqa: BLE001 -- se reintenta en el siguiente minuto
            if guard_info["error"] != repr(e):
                log(f"ERROR en la guardia de descargas: {e!r}")
            guard_info["error"] = repr(e)
        # Con un "abrir" pendiente se mira cada 5 s, para reanudar en cuanto
        # qBittorrent responda.
        time.sleep(5 if QBT_NATIVO and open_requested() else GUARD_S)


# ---------------------------------------------------------------------------
# Descargas atascadas (spec 028): sin completar, sin fuentes y sin actividad
# desde hace STALLED_S. Quitarlas es un boton, nunca automatico: Radarr/
# Sonarr las borran de qBittorrent, ponen ese release en la lista negra y
# buscan otro (DELETE queue/bulk con blocklist y sin skipRedownload).
# ---------------------------------------------------------------------------
STALLED_STATES = {"stalledDL", "metaDL", "forcedMetaDL"}


def arr_queue():
    """{hash en minusculas: {app, ids, title}} de la cola de Radarr/Sonarr."""
    out = {}
    for app, extra in (("radarr", "includeMovie=true&includeUnknownMovieItems=true"),
                       ("sonarr", "includeSeries=true&includeUnknownSeriesItems=true")):
        page = arr_get(app, f"queue?page=1&pageSize=2000&{extra}") or {}
        for rec in page.get("records", []):
            h = (rec.get("downloadId") or "").lower()
            if not h:
                continue
            item = out.setdefault(h, {"app": app, "ids": [], "title": None})
            item["ids"].append(rec["id"])
            what = rec.get("movie") or rec.get("series") or {}
            item["title"] = item["title"] or what.get("title")
    return out


def stalled_list():
    now = time.time()
    torrents = Qbt().torrents()
    stuck = [t for t in torrents if t.get("state") in STALLED_STATES
             and now - max(t.get("last_activity") or 0, t.get("added_on") or 0) > STALLED_S]
    queue = arr_queue() if stuck else {}
    rows = []
    for t in stuck:
        q = queue.get(t["hash"].lower())
        rows.append({
            "hash": t["hash"], "name": t.get("name"), "state": t.get("state"),
            "progress": t.get("progress"), "size": t.get("size"),
            "seeds": t.get("num_seeds"), "seeds_total": t.get("num_complete"),
            "since": int(max(t.get("last_activity") or 0, t.get("added_on") or 0)),
            "app": q["app"] if q else None, "title": q["title"] if q else None,
        })
    rows.sort(key=lambda r: r["since"])
    return rows


def arr_bulk_remove(app, ids):
    q = "removeFromClient=true&blocklist=true&skipRedownload=false"
    req = urllib.request.Request(f"{ARRS[app]}/api/v3/queue/bulk?{q}", data=json.dumps({"ids": ids}).encode(),
                                 method="DELETE",
                                 headers={"X-Api-Key": arr_key(app) or "", "Content-Type": "application/json"})
    urllib.request.urlopen(req, timeout=60).read()


def remove_stalled(hashes, delete_manual=False):
    """Solo las que siguen atascadas AHORA y estan en la cola de Radarr/
    Sonarr; lo demas se rechaza. delete_manual (spec 033): las que Radarr/
    Sonarr no conocen se quitan de qBittorrent con sus archivos."""
    wanted = {h.lower() for h in hashes if isinstance(h, str)}
    current = {r["hash"].lower(): r for r in stalled_list()}
    queue = arr_queue()
    results = []
    for h in wanted:
        r = {"hash": h, "ok": False}
        results.append(r)
        row, q = current.get(h), queue.get(h)
        if row is None:
            r["error"] = "ya no está atascada"
            continue
        r["name"] = row["name"]
        if q is None and delete_manual:
            try:
                Qbt().delete(row["hash"], True)
                r["ok"] = True
                log(f"ATASCADA manual borrada de qBittorrent con sus archivos: {row['name']}")
            except Exception as e:  # noqa: BLE001
                r["error"] = str(e)
            continue
        if q is None:
            r["error"] = "no está en la cola de Radarr/Sonarr"
            continue
        try:
            arr_bulk_remove(q["app"], q["ids"])
            r["ok"] = True
            log(f"ATASCADA descartada ({q['app']}, lista negra + nueva búsqueda): {row['name']}")
        except Exception as e:  # noqa: BLE001
            r["error"] = str(e)
    return results


# ---------------------------------------------------------------------------
# Tarjeta para la home (Homer, bloque "message" con url): la misma barra que
# la pagina + el boton de descargas. Homer pide esto desde el navegador y lo
# pinta con innerHTML; si la respuesta no es un 200 con JSON deja de
# refrescarla hasta recargar, asi que siempre se contesta 200.
# ---------------------------------------------------------------------------
def esc(s):
    return (str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            .replace('"', "&quot;").replace("'", "&#39;"))


def fmt_es(n):
    """Como fmt() de la pagina (JS): coma decimal y sin decimales desde 100."""
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1024 or unit == "TB":
            if unit == "B":
                return f"{n:.0f} B"
            return (f"{n:.0f}" if n >= 100 else f"{n:.1f}").replace(".", ",") + f" {unit}"
        n /= 1024


def homer_downloads_html(base):
    s = downloads_status()
    if s["opening"]:
        return ('<div class="mc-dl is-paused"><span>Abriendo qBittorrent en Windows (hasta un minuto)…</span>'
                '<button type="button" disabled>Abriendo…</button></div>')
    if s["closed"]:
        text, btn, action = "qBittorrent está cerrado", "Abrir qBittorrent", "start"
    elif s["paused"]:
        why = ("por poco espacio: se reanuda solo por encima de " + fmt_es(s["resume_at"])
               if s.get("reason") == "auto" else "a mano")
        text, btn, action = f"Descargas paradas {why}", "Reanudar descargas", "start"
    else:
        text, btn, action = "qBittorrent en marcha", "Parar descargas", "stop"
    # onclick en linea: Homer no ejecuta <script> de innerHTML pero si los
    # atributos de evento (y no manda CSP). Al terminar se sustituye este
    # bloque por el que devuelve el POST.
    js = ("var b=this,box=b.closest('.mc-dl');b.disabled=true;b.textContent='Un momento…';"
          f"fetch('{base}/api/downloads/{action}',{{method:'POST',headers:{{'Content-Type':'application/json'}},body:'{{}}'}})"
          ".then(function(r){return r.json()}).then(function(j){if(j.html){box.outerHTML=j.html}"
          "else{b.textContent=j.error||'Error';}}).catch(function(){b.textContent='Sin conexión'})")
    err = f'<div class="mc-err">{esc(s["error"])}</div>' if s.get("error") else ""
    return (f'<div class="mc-dl{" is-paused" if s["paused"] or s["closed"] else ""}"><span>{esc(text)}</span>'
            f'<button type="button" onclick="{esc(js)}">{btn}</button>{err}</div>')


def homer_card(base):
    with lock:
        r = state["report"]
    d = disk_usage(DATA)
    pct = d["free"] / d["total"] * 100 if d["total"] else 0
    pct_s = f"{pct:.1f}".replace(".", ",")
    ghost = r["ghost_total"] if r else 0
    kpis = (f'<div class="mc-kpis"><div><b>{fmt_es(d["free"])}</b><small>libres ({pct_s}%)</small></div>'
            + f'<div><b>{fmt_es(d["total"])}</b><small>en total</small></div>'
            + (f'<div class="mc-ghost"><b>{fmt_es(ghost)}</b><small>fantasma, recuperable</small></div>' if r else "")
            + "</div>")
    bar = legend = ""
    if r:
        f = {x["key"]: x["bytes"] for x in r["folders"]}
        segs = [("Biblioteca", f.get("movies", 0) + f.get("tv", 0), "#7c6cff"),
                ("Fantasma", ghost, "#e0529c"),
                ("Descargas a medias", f.get("incomplete", 0), "#f5b041"),
                ("Configuración", r["disk"].get("config") or 0, "#4aa3c7"),
                ("Fuera del MediaCenter", r["disk"]["other"], "#555a6e")]
        segs = [s for s in segs if s[1] > 0]
        bar = '<div class="mc-bar">' + "".join(
            f'<span title="{esc(l)}: {fmt_es(b)}" style="width:{b / d["total"] * 100:.2f}%;background:{c}"></span>'
            for l, b, c in segs) + "</div>"
        legend = '<div class="mc-legend">' + "".join(
            f'<span><i style="background:{c}"></i>{esc(l)} · {fmt_es(b)}</span>' for l, b, c in segs) + \
            f'<span><i class="mc-free"></i>Libre · {fmt_es(d["free"])}</span></div>'
    # Actualizaciones (spec 042): solo si hay alguna.
    n_upd = len(((updates_status()["result"] or {}).get("updates") or [])) if QBT_NATIVO else 0
    upd = (f'<a href="{base}/#actualizaciones">{n_upd} actualizaci{"ón" if n_upd == 1 else "ones"}</a> · '
           if n_upd else "")
    # Version nueva de MediaCenter (spec 051).
    app = app_status()
    if app["available"] and QBT_NATIVO:
        upd = f'<a href="{base}/#mediacenter">MediaCenter {esc(app["latest"]["latest"])} disponible</a> · ' + upd
    # Comprobacion (spec 049): solo si algo falla.
    n_bad = ((verify_status()["result"] or {}).get("summary") or {}).get("fallo") or 0
    if n_bad:
        upd = (f'<a class="mc-bad" href="{base}/#comprobacion">⚠ {n_bad} problema{"" if n_bad == 1 else "s"}'
               f' en la instalación</a> · ') + upd
    # Bloqueos de LaLiga (spec 050): arriba del todo, mientras dure.
    fb = football["status"] or {}
    if fb.get("active"):
        kpis = f'<div class="mc-futbol">{esc(fb["message"])}</div>' + kpis
    return (f'<div class="mc-disk">{kpis}{bar}{legend}'
            f'<div class="mc-foot">{homer_downloads_html(base)}'
            f'<span>{upd}<a href="{base}/">Ver detalle</a></span></div></div>')


class Handler(BaseHTTPRequestHandler):
    def send(self, code, body, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        # Para el punto de estado ("Ping") de Homer, que pregunta desde el
        # navegador en otro puerto.
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def send_json(self, obj, code=200):
        self.send(code, json.dumps(obj).encode(), "application/json; charset=utf-8")

    def do_GET(self):  # noqa: N802
        path = urllib.parse.urlparse(self.path).path
        if path in ("/", "/index.html"):
            with open(os.path.join(STATIC, "index.html"), "rb") as f:
                self.send(200, f.read(), "text/html; charset=utf-8")
        elif path == "/api/report":
            downloads = downloads_status()  # fuera de `lock`: puede esperar a la guardia
            with lock:
                self.send_json({"report": state["report"], "scanning": state["scanning"],
                                "error": state["error"], "imports": imports_log,
                                "auto_import": AUTO_IMPORT,
                                "auto_import_after_hours": AUTO_IMPORT_AFTER_S / 3600,
                                "downloads": downloads, "extras_job": extras_status(),
                                "updates": updates_status() if QBT_NATIVO else None,
                                "verify": verify_status(),
                                "app": app_status(),
                                "football": football["status"],
                                "subtitles_job": {k: v for k, v in subs_job.items() if k != "profiles"}})
        elif path == "/api/homer":
            try:
                content = homer_card(self.base())
            except Exception as e:  # noqa: BLE001 -- 200 siempre, o Homer deja de refrescar
                content = f'<div class="mc-err">No se puede leer el disco: {esc(e)}</div>'
            self.send_json({"title": "Disco", "content": content})
        elif path == "/api/stalled":
            try:
                self.send_json({"stalled": stalled_list(), "hours": STALLED_S / 3600})
            except Exception as e:  # noqa: BLE001
                self.send_json({"stalled": [], "hours": STALLED_S / 3600, "error": str(e)})
        elif path == "/health":
            self.send(200, b"ok", "text/plain")
        else:
            self.send(404, b"not found", "text/plain")

    def do_OPTIONS(self):  # noqa: N802 -- preflight del boton de Homer
        path = urllib.parse.urlparse(self.path).path
        origin = self.homer_origin(path)
        self.send_response(204 if origin else 403)
        if origin:
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Access-Control-Allow-Methods", "POST")
            self.send_header("Access-Control-Allow-Headers", "Content-Type")
            self.send_header("Access-Control-Max-Age", "600")
        self.end_headers()

    def do_HEAD(self):  # noqa: N802 -- Homer "Ping" usa HEAD
        self.send_response(200 if urllib.parse.urlparse(self.path).path in ("/", "/health") else 404)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()

    def base(self):
        """URL de esta pagina tal como la ve el navegador (para los enlaces y
        el boton de la tarjeta de Homer)."""
        host = self.headers.get("Host", "")
        return f"http://{host}" if re.fullmatch(r"[\w.-]+(:\d+)?|\[[0-9a-fA-F:]+\](:\d+)?", host) else ""

    def homer_origin(self, path):
        """La home (Homer) puede parar/reanudar qBittorrent: Homer en esta
        maquina (HOST_LAN_IP, localhost o el host de la peticion), puerto de
        Homer. Nada mas: ni otros endpoints (borran
        cosas) ni otros origenes."""
        origin = self.headers.get("Origin")
        if not origin or not path.startswith("/api/downloads/"):
            return None
        # Homer puede abrirse por otra direccion que la de la tarjeta (esta
        # pide siempre a HOST_LAN_IP): p.ej. localhost:3000 en el propio PC.
        hosts = {"localhost", "127.0.0.1", "::1"} | ({HOST_LAN_IP} if HOST_LAN_IP else set())
        try:
            o = urllib.parse.urlparse(origin)
            hosts.add(urllib.parse.urlparse("//" + self.headers.get("Host", "")).hostname)
            ok = o.scheme == "http" and o.hostname in hosts and str(o.port) == HOMER_PORT
        except ValueError:  # puerto no numerico
            ok = False
        if not ok:
            log(f"Rechazado el origen {origin} para {path} (solo Homer, puerto {HOMER_PORT}, en {sorted(h for h in hosts if h)})")
        return origin if ok else None

    def same_origin(self, path=""):
        """Solo la propia pagina puede pedir cambios: sin esto, cualquier web
        abierta en un navegador de la LAN podria mandar un POST aqui. El
        Content-Type JSON obliga ademas al navegador a pedir permiso (CORS
        preflight) a otros origenes, y aqui solo se concede a Homer para
        /api/downloads/* (ver homer_origin)."""
        origin = self.headers.get("Origin")
        if (origin and urllib.parse.urlparse(origin).netloc != self.headers.get("Host")
                and not self.homer_origin(path)):
            return False
        return self.headers.get("Content-Type", "").startswith("application/json")

    def do_POST(self):  # noqa: N802
        path = urllib.parse.urlparse(self.path).path
        if path not in ("/api/rescan", "/api/delete", "/api/import", "/api/library-delete",
                        "/api/downloads/stop", "/api/downloads/start", "/api/stalled/remove",
                        "/api/extras/import", "/api/updates/check", "/api/updates/apply", "/api/subtitles/search",
                        "/api/verify", "/api/app-update", "/api/app-update/check"):
            self.send(404, b"not found", "text/plain")
            return
        if not self.same_origin(path):
            self.send(403, b"forbidden", "text/plain")
            return
        if path == "/api/rescan":
            wake.set()
            self.send_json({"ok": True})
            return
        if path == "/api/extras/import":
            self.send_json(request_extras_import())
            return
        if path == "/api/verify":
            self.send_json(run_verify())
            return
        if path == "/api/app-update":
            self.send_json(request_app_update())
            return
        if path == "/api/app-update/check":
            if not (MC_VERSION and MC_VERSION != "dev"):
                self.send_json({"ok": False, "error": "Esta instalación no tiene versión (copia de desarrollo)."})
                return
            try:
                app_check_latest()
                self.send_json({"ok": True})
            except Exception as e:  # noqa: BLE001
                self.send_json({"ok": False, "error": f"No se ha podido mirar: {e}"})
            return
        if path in ("/api/updates/check", "/api/updates/apply"):
            self.send_json(request_updates(path.endswith("/apply")) if QBT_NATIVO
                           else {"ok": False, "error": "Solo con qBittorrent en Windows (hace falta su tarea programada)."})
            return
        if path in ("/api/downloads/stop", "/api/downloads/start"):
            r = downloads_action(path.endswith("/stop"))
            if r["ok"]:
                r["html"] = homer_downloads_html(self.base())
            self.send_json(r)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(min(length, 65536)) or b"{}")
            paths = body.get("paths", [])
            items = body.get("items", [])
        except (ValueError, AttributeError):
            self.send_json({"error": "petición no válida"}, 400)
            return
        if path == "/api/subtitles/search":  # en segundo plano: no rescanear ya
            self.send_json(search_subtitles(items if isinstance(items, list) else []))
            return
        if path == "/api/library-delete":
            with delete_lock:
                results = remove_library_items(items if isinstance(items, list) else [])
        elif path == "/api/stalled/remove":
            hashes = body.get("hashes", [])
            try:
                results = remove_stalled(hashes if isinstance(hashes, list) else [],
                                         delete_manual=body.get("mode") == "delete")
            except Exception as e:  # noqa: BLE001
                results = [{"ok": False, "error": str(e)}]
        elif path == "/api/import":
            with delete_lock:
                results = import_paths(paths)
        else:
            results = delete_paths(paths, allow_risky=body.get("allow_risky") is True)
        self.send_json({"results": results})
        wake.set()  # que la pagina lo refleje

    def log_message(self, fmt_, *args):
        pass  # sin una linea de log por cada peticion de la pagina


class DualStackServer(ThreadingHTTPServer):
    """IPv4 e IPv6 a la vez: dentro del contenedor "localhost" resuelve
    primero a ::1 (lo usa el healthcheck)."""
    address_family = socket.AF_INET6

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()


if __name__ == "__main__":
    log(f"Arrancado. Re-escaneo cada {INTERVAL_S / 3600:g} h; pagina en el puerto {PORT}.")
    threading.Thread(target=scanner, daemon=True).start()
    threading.Thread(target=verifier, daemon=True).start()
    threading.Thread(target=football_watch, daemon=True).start()
    threading.Thread(target=guard, daemon=True).start()
    DualStackServer(("::", PORT), Handler).serve_forever()
