#!/usr/bin/env python3
# =============================================================================
# clean.py — borra descargas fantasma desde la terminal (spec 021, fase 2).
# Se lanza con scripts\borrar-fantasmas.ps1. Alternativa al boton de la
# pagina "Espacio en disco": mismas reglas y mismas comprobaciones (viven en
# server.py, seccion "Borrado"). Por defecto, a diferencia de la pagina, NO
# ofrece las descargas que Radarr/Sonarr no conocen (--incluir-desconocidas).
# =============================================================================
import argparse
import sys
import urllib.request

import server
from server import block_reason, fmt


def say(msg=""):
    print(msg, flush=True)


def describe(g):
    a = g.get("arr")
    if not a:
        why = "descarga manual, no está en la biblioteca"
    elif a["verdict"] == "gone":
        why = "ya no está en Radarr/Sonarr"
    else:
        why = f"{a.get('title')}: ya hay otra versión en la biblioteca"
    if g["status"] == "parcial":
        why += f" · solo {len(g['files'])} archivo(s); {g['linked_files']} siguen en la biblioteca y no se tocan"
    return why


def choose(n):
    say("Escribe  borrar  para borrar todo lo de la lista, unos números separados por comas")
    say("(p.ej. 1,3,7) para borrar solo esos, o pulsa Enter para salir sin borrar nada.")
    try:
        ans = input("> ").strip().lower()
    except EOFError:
        return []
    if ans == "borrar":
        return list(range(n))
    if not ans:
        return []
    try:
        picked = sorted({int(x) - 1 for x in ans.replace(" ", "").split(",") if x})
    except ValueError:
        say("No entiendo esa respuesta; no se borra nada.")
        return []
    if any(i < 0 or i >= n for i in picked):
        say("Algún número no está en la lista; no se borra nada.")
        return []
    return picked


def main():
    ap = argparse.ArgumentParser(description="Borra descargas fantasma que ya no hacen falta.")
    ap.add_argument("--solo-ver", action="store_true", help="solo enseña qué se borraría")
    ap.add_argument("--incluir-desconocidas", action="store_true",
                    help="ofrece también descargas que Radarr/Sonarr no conocen (descargas manuales)")
    args = ap.parse_args()

    # La limpieza no necesita el peso de /config (lo lento del escaneo).
    server.config_walk = lambda: []
    server.log = lambda msg: None

    say("Midiendo el disco y preguntando a qBittorrent/Radarr/Sonarr...")
    report = server.scan()
    ok, skip = [], []
    for g in report["ghosts"]:
        reason = block_reason(g, args.incluir_desconocidas)
        (skip.append((g, reason)) if reason else ok.append(g))

    if skip:
        say()
        say("NO se tocan:")
        for g, why in skip:
            say(f"  - {g['name']}  ({fmt(g['ghost_bytes'])}) — {why}")

    say()
    if not ok:
        say("No hay nada que se pueda borrar sin riesgo.")
        return 0
    say(f"Se pueden borrar ({fmt(sum(g['ghost_bytes'] for g in ok))} en {len(ok)} descargas):")
    for i, g in enumerate(ok, 1):
        say(f"  {i:>2}. {g['name']}  [{fmt(g['ghost_bytes'])}]")
        say(f"      {describe(g)}")
    say()

    if args.solo_ver:
        say("(Modo --solo-ver: no se ha borrado nada.)")
        return 0
    if not sys.stdin.isatty():
        say("Hace falta una terminal para confirmar; no se borra nada.")
        return 1

    picked = choose(len(ok))
    if not picked:
        say("No se ha borrado nada.")
        return 0

    qbt = None
    freed = 0
    for i in picked:
        say(f"Borrando {ok[i]['name']}...")
        try:
            # Se vuelve a analizar en este momento, igual que desde la pagina.
            g = server.fresh_ghost(ok[i]["path"])
            if g is None:
                raise RuntimeError("ya no es un fantasma (o ya no existe)")
            reason = block_reason(g, args.incluir_desconocidas)
            if reason:
                raise RuntimeError(reason)
            if g.get("qbt") and qbt is None:
                qbt = server.Qbt()
            b = server.delete_ghost(g, qbt)
            freed += b
            say(f"    OK, {fmt(b)} liberados.")
            print(f"[disk-clean] borrado: {g['path']} ({b} bytes)", file=sys.stderr, flush=True)
        except Exception as e:  # noqa: BLE001 -- se sigue con el resto
            say(f"    NO se ha borrado: {e}")
            print(f"[disk-clean] omitido: {ok[i]['path']} ({e})", file=sys.stderr, flush=True)

    say()
    say(f"Listo: {fmt(freed)} liberados.")
    try:  # que la pagina lo refleje ya
        urllib.request.urlopen(urllib.request.Request(
            "http://disk-report:8080/api/rescan", data=b"{}", method="POST",
            headers={"Content-Type": "application/json"}), timeout=5)
    except Exception:  # noqa: BLE001 -- la pagina se actualizara sola
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
