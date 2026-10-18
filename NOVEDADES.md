# MediaCenter 2026.10.18.3

Cambios del 2026-10-18:

- **Descargas propias fuera de `torrents/`**: lo que se abre a mano en
  qBittorrent (magnet o `.torrent` sin categoría) va a `data\descargas`. En
  `torrents\`, el panel de disco lo tomaba por "fantasma, recuperable" y
  ofrecía borrarlo. Radarr y Sonarr no cambian: usan sus categorías. Lo que
  ya había no se ha movido (`save_path_changed_tmm_enabled: false`).

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
