# MediaCenter 2026.10.18.2

Cambios del 2026-10-18:

- **Enlaces magnet y .torrent**: abrían un segundo qBittorrent con el
  perfil normal, en vez de añadirse al de MediaCenter, porque el
  instalador de qBittorrent los registra sin `--profile`. Ahora el
  instalador de MediaCenter los registra con el perfil, en el usuario, y
  se pasan al qBittorrent ya abierto. Aplicado a mano en este PC.

- **Actualizar MediaCenter desde el panel**: las versiones se publican en
  el repo público `DiegoSMR/MediaCenter-App-Download`
  (`installer-exe\publicar.ps1`). El panel avisa y actualiza con un botón:
  copia de seguridad, comprobación antes y después, y vuelta atrás si algo
  falla. Las instalaciones anteriores tienen que reinstalar una vez con el
  `.exe` nuevo.
