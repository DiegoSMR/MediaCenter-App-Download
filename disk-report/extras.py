#!/usr/bin/env python3
# =============================================================================
# extras.py — extras dentro de la carpeta de cada pelicula/serie (specs 035
# y 036). Lo lanza scripts\importar-extras.ps1, nunca solo. Este contenedor
# solo LEE /data: los enlaces los hace PowerShell en Windows (un hardlink no
# cruza montajes de Docker, y nada de disk-report debe poder escribir en la
# biblioteca). La planificacion vive en server.py (seccion "Extras"), que
# tambien la usa en cada escaneo para la pagina.
#
#   extras.py plan              -> una linea "PLAN:{json}": extras sin
#                                  enlazar y descargas con extras de dueno
#                                  desconocido.
#   extras.py refresh CARPETA.. -> Jellyfin vuelve a leer esas peliculas/
#                                  series (rutas /data/media/...).
# =============================================================================
import json
import os
import sys
import urllib.parse
import urllib.request

import server
from server import CATEGORY_DIRS, MEDIA, TORRENTS


def plan():
    items, unknown = server.extras_plan(server.walk_files(MEDIA), server.walk_files(TORRENTS), CATEGORY_DIRS)
    # ensure_ascii: PowerShell 5.1 estropea el UTF-8 de la salida de docker.
    print("PLAN:" + json.dumps({"items": items, "unknown": unknown}))


def refresh(folders):
    """Pide a Jellyfin que vuelva a leer esas peliculas/series. Avisar de
    la carpeta cambiada (/Library/Media/Updated, lo que hace Radarr) NO
    basta: los extras nuevos no aparecian hasta refrescar el elemento
    (comprobado 2026-09-30)."""
    key = server.service_key("jellyseerr/settings.json", "jellyfin", "apiKey")
    if not key:
        raise RuntimeError("no hay clave de Jellyfin (jellyseerr/settings.json)")

    def call(path, method="GET"):
        req = urllib.request.Request(f"http://jellyfin:8096{path}", method=method, headers={"Authorization": f'MediaBrowser Token="{key}"'})
        body = urllib.request.urlopen(req, timeout=60).read()
        return json.loads(body) if body else None

    q = urllib.parse.urlencode({"Recursive": "true", "IncludeItemTypes": "Movie,Series", "Fields": "Path"})
    wanted = set(folders)
    # Pelicula: Path = su archivo (la carpeta es el padre). Serie: Path = su carpeta.
    found = [i for i in call(f"/Items?{q}").get("Items", [])
             if i.get("Path") and (i["Path"] in wanted or os.path.dirname(i["Path"]) in wanted)]
    for i in found:
        call(f"/Items/{i['Id']}/Refresh?Recursive=true&MetadataRefreshMode=Default&ImageRefreshMode=Default", "POST")
    missing = len(wanted) - len({i["Path"] if i["Path"] in wanted else os.path.dirname(i["Path"]) for i in found})
    print(f"Jellyfin: releyendo {len(found)} película(s)/serie(s); los extras aparecen en su ficha en un minuto."
          + (f" {missing} no las encuentra aún: se verán en su próximo escaneo." if missing > 0 else ""))


def main():
    server.log = lambda msg: None
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "plan":
        plan()
    elif cmd == "refresh" and len(sys.argv) > 2:
        refresh(sys.argv[2:])
    else:
        print("uso: extras.py plan | refresh CARPETA...", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
