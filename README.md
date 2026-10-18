# MediaCenter

Todo esta muy caro y estoy hasta los cojones,el cine esta caro,
 netflix  caro, disney pone anuncios, amazon te para el ultimo capitulo de the boys para ponerte mas anuncios,
 Apple TV esta guapa, pero seamos sinceros, no lo tiene nadie y eso no puede ser ya
ROBAD ROBAD ROBAD ROBAD ROBAD ROBAD ROBAD ROBAD ROBAD ROBAD ROBAD ROBADROBAD ROBAD ROBAD ROBAD ROBAD ROBAD

Bajaos Backrooms, es una mierda, me la suda, robad Backrooms por amor al arte.

Espero que este instaler haga sencillo montar una cosa que ha sido un puo cristo

## Qué necesitas

- Un PC con **Windows 11** (con Windows 10 no funciona) y al menos **8 GB
  de memoria RAM**.
- ** espacio en disco**: cada película ocupa entre 2 y 10 GB (Se puede elegir
de forma manual), y una
  temporada de una serie bastante más. Mejor un disco con 500 GB libres o
  más.
- **Internet**. La primera instalación descarga varios GB.
- Que ese PC **pueda quedarse encendido**: si está apagado o suspendido, no
  descarga y no se puede ver nada desde la tele.

## Instalarlo

1. Abre **`MediaCenter-Setup.exe`**.
2. Windows enseña un aviso azul: *"Windows protegió su PC"*. Es normal (el
   instalador no está "firmado" por una empresa): pulsa **"Más
   información"** y después **"Ejecutar de todas formas"**.
3. Al aviso *"¿Quieres permitir que esta aplicación haga cambios?"*, pulsa
   **Sí**.
4. Contesta tres preguntas:
   - **Dónde guardar las películas y series**: propone el disco con más
     espacio; normalmente basta con dejarlo así.
   - **Un usuario y una contraseña**: los usarás para entrar desde la tele
     y el móvil, así que apúntalos. La contraseña tiene que tener al menos
     6 caracteres y no puede llevar comilla simple (').
   - **OpenSubtitles** (opcional, pero recomendado): es de los mejores
     sitios de subtítulos. Necesita una cuenta gratuita, que se crea en
     [opensubtitles.com](https://www.opensubtitles.com). Si lo dejas en
     blanco, los subtítulos se buscan igual en otros sitios.
5. Deja marcada la casilla **"No suspender el PC mientras esté enchufado"**.
6. **Espera.** Se abre una ventana negra con el progreso: no la cierres.
7. Si te pide **reiniciar**, acepta. Al volver, **inicia sesión en Windows
   y espera**: se abrirá sola una ventana que termina la instalación.
8. Al terminar se abre la página **"Primeros pasos"**, que también queda en
   el escritorio.

En total tarda una media hora, esta casi  todo automatizado

## Usarlo

- **Para ver películas y series**, instala la app **Jellyfin** (gratis) en
  la tele o en el móvil: está en Google Play, App Store y en la tienda de
  aplicaciones de las teles Samsung, LG y Android TV. Te pedirá la
  dirección del servidor: está en "Primeros pasos", con un código QR para
  el móvil. Entra con tu usuario y tu contraseña.
- **Para pedir algo nuevo**, abre **Seerr** (dirección en "Primeros pasos"),
  busca la película o serie y pulsa **Solicitar**. Se descarga sola y
  aparece en Jellyfin cuando termina: de minutos a unas horas, según su
  tamaño y lo popular que sea.
- **El panel**, en el acceso directo **"MediaCenter"** del escritorio,
  muestra todas las aplicaciones, cuánto espacio queda en el disco y lo
  que necesite tu atención (apartado "Pendiente").
- **Los subtítulos** en español e inglés se buscan solos.

## Cosas que conviene saber

- **El PC tiene que estar encendido.** Si lo reinicias, inicia sesión en
  Windows: todo vuelve a arrancar solo al entrar, aunque tarda unos
  minutos.
- **No cierres Docker Desktop.** Es el programa que mueve todo por dentro.
  Si lo cierras, nada funciona hasta que lo vuelvas a abrir desde el menú
  Inicio.
- **qBittorrent** es el programa que descarga. Funciona oculto, con su
  icono junto al reloj. Cerrar su ventana con la X no lo cierra. Si lo
  cierras del todo, el panel tiene un botón para volver a abrirlo.
- **Si el disco se va llenando**, el panel avisa, y las descargas se paran
  solas antes de que se llene del todo.
- **Descargas más rápidas (opcional):** si tu router lo permite, abre el
  puerto `6881` (TCP y UDP) hacia este PC. "Primeros pasos" explica cómo.
  Si tu compañía no lo permite, funciona igual, solo algo más lento.
- **Lo que descargas es responsabilidad tuya.** MediaCenter busca en
  fuentes públicas de internet.

## Si algo no funciona

- **La instalación falla o se queda a medias:** vuelve a ejecutar
  `MediaCenter-Setup.exe`. No borra nada y termina lo que falte. Muchas
  veces es solo un corte de internet.
- **Te dice que la virtualización está desactivada:** hay que activarla en
  la BIOS del PC, y el propio mensaje explica cómo. Si no te atreves, pide
  ayuda a quien te pasó el instalador.
- **La tele o el móvil no conectan:**
  - Comprueba que están en el mismo WiFi que el PC.
  - Comprueba que el PC está encendido y que Docker Desktop está abierto.
  - Si funcionaba y ha dejado de hacerlo, puede que el router le haya
    cambiado la dirección al PC. Vuelve a ejecutar el instalador y usa la
    dirección nueva que aparece en "Primeros pasos".
- **Sigue fallando:** pásale a quien te lo instaló el archivo
  `C:\MediaCenter\instalacion.log`.

## Desinstalar

Configuración de Windows > Aplicaciones > **MediaCenter** > Desinstalar.
Pregunta si quieres borrar también las películas y series. Si dices que
no, se quedan en el disco y puedes reinstalar sin perder nada. Docker
Desktop y qBittorrent se quedan instalados; si no los quieres, se quitan
aparte desde el mismo sitio.

---

# Parte técnica (para quien lo mantiene)

Stack Docker Compose para Windows 11 + Docker Desktop + WSL2: Radarr,
Sonarr, Prowlarr, qBittorrent, Bazarr, Recyclarr, Jellyfin, Seerr y
Homer. Con `docker compose up -d --build` (o `scripts\start.ps1`) el stack
arranca conectado: Prowlarr sabe de Radarr y Sonarr, ambos ya tienen a
qBittorrent como cliente de descargas con categorías `movies`/`tv`
separadas, sus carpetas raíz configuradas, el login está desactivado
dentro de tu LAN, y el panel (Homer) se genera con los enlaces ya
apuntando a tu IP. No hay ninguna ruta de Windows hardcodeada: todo
depende de `.env`.

## 1. Arquitectura

```
Seerr -> Radarr/Sonarr -> Prowlarr (indexadores) -> qBittorrent -> biblioteca -> Jellyfin
```

- **Prowlarr** solo gestiona indexadores (no se usa para nada más).
- **Recyclarr** mantiene los perfiles de calidad de Radarr/Sonarr sincronizados con TRaSH Guides.
- **Seerr** (antes Jellyseerr) es la interfaz para buscar y solicitar contenido.
- Todos los servicios están en la red Docker `arrnet` y se hablan por nombre
  de servicio (`http://radarr:7878`, `http://qbittorrent:8080`, ...). Nunca
  `localhost` entre contenedores.
- No se expone nada a Internet. Todo es solo-LAN.

## 2. Estructura de carpetas (host)

```
D:\MEDIA\
├── data\
│   ├── torrents\
│   │   ├── movies\      <- categoría "movies" de qBittorrent
│   │   └── tv\           <- categoría "tv" de qBittorrent
│   └── media\
│       ├── movies\       <- carpeta raíz de Radarr
│       └── tv\           <- carpeta raíz de Sonarr
├── config\
│   ├── radarr\ sonarr\ prowlarr\ bazarr\ qbittorrent\ recyclarr\
│   └── jellyfin\ jellyseerr\ homer\
└── backup\               <- ver sección 7
```

**Por qué hay hardlinks garantizados (sin duplicar espacio en disco):**
Radarr y Sonarr montan **todo `${DATA_ROOT}` como un único volumen `/data`**
(torrents y media dentro del mismo mount), así que al importar una descarga
completa desde `/data/torrents/movies` hacia `/data/media/movies` pueden
hardlinkear en vez de copiar. qBittorrent, Bazarr y Jellyfin solo montan la
parte de `/data` que necesitan (torrents o media, no ambas) por principio de
mínimo acceso — eso no afecta al hardlink, que solo depende de Radarr/Sonarr.

**qBittorrent en este PC va fuera de Docker (instalado en Windows).** Dentro
del contenedor iba muy lento (menos de 300 KB/s, conectando con muy pocas
fuentes) y se colgaba al suspender el PC. Instalado en Windows, en la misma
conexión, bajó a unos 58 MB/s. Cómo queda:

- Se abre solo al iniciar sesión, oculto en la bandeja del sistema (tarea
  programada "MediaCenter qBittorrent"). Su configuración está en
  `D:\MEDIA\config\qbittorrent-nativo`, dentro del backup.
- La web sigue en `http://<IP>:8080`, con el mismo usuario y contraseña.
- `scripts\start.ps1`, `stop.ps1`, `restart.ps1` y `status.ps1` también lo
  arrancan, lo paran y muestran su estado.
- Si lo cierras (bandeja → Salir), se queda cerrado. La tarjeta "Disco" del
  panel dirá **"qBittorrent está cerrado"**; su botón **"Abrir
  qBittorrent"** lo abre en menos de un minuto y reanuda lo que hubieras
  parado con el botón. Lo hace una tarea de Windows ("MediaCenter
  qBittorrent (panel)") que se ejecuta un instante cada minuto, sin
  ventana y sin quedarse en memoria.
- Radarr, Sonarr y la página Espacio en disco lo encuentran solos
  (`QBT_URL` y `QBT_DATA_DIR` en `.env`, configurados por `bootstrap`).
- El contenedor de qBittorrent sigue en `docker-compose.yml`, pero
  desactivado (`docker-compose.override.yml`). Para volver a él, borra ese
  fichero y las dos líneas `QBT_...` de `.env`, cierra el qBittorrent de
  Windows, desactiva la tarea programada y ejecuta
  `docker compose up -d`.
- Los hardlinks siguen funcionando: comprobado que Radarr, desde Docker,
  enlaza lo que descarga el qBittorrent de Windows (2 enlaces, sin
  duplicar espacio).

## 3. Variables (`.env`)

Todas las rutas dependientes de esta máquina están en un único `.env` (no
está en el repo/backup de código, cópialo desde `.env.example`):

| Variable | Valor en esta máquina |
|---|---|
| `DATA_ROOT` | `D:/MEDIA/data` |
| `CONFIG_ROOT` | `D:/MEDIA/config` |
| `BACKUP_ROOT` | `D:/MEDIA/backup` — ver sección 8, debería ser otro disco físico |
| `BACKUP_INTERVAL_HOURS` | `24` |
| `DISK_REPORT_INTERVAL_HOURS` | `1` — cada cuánto se re-mide el disco para la página Espacio en disco |
| `DISK_MIN_FREE_GB` | `50` — por debajo, las descargas se paran solas (se reanudan con 20 GB más) |
| `STALLED_HOURS` | `6` — horas sin avanzar para que una descarga salga como atascada |
| `HOST_LAN_IP` | IP LAN de este PC, para que los enlaces del panel (Homer) funcionen desde el móvil/TV (no localhost) |
| `PUID` / `PGID` / `TZ` | `1000` / `1000` / `Europe/Madrid` |

> Recomendado: fija una **reserva DHCP** en tu router para `HOST_LAN_IP` para
> que no cambie; si cambia, actualiza `.env` y `docker compose up -d --force-recreate bootstrap`.

## 4. Arranque

**Opción A — instalador interactivo** (recomendado para una instalación
desde cero): te pregunta las rutas/IP, arranca todo, y al final te dice
exactamente qué pasos manuales te quedan (con tu IP real ya puesta, no
un placeholder):

```powershell
scripts\install.ps1
```

**Opción B — a mano**:

```powershell
docker compose up -d --build
```

o simplemente:

```powershell
scripts\start.ps1
```

(requiere haber copiado `.env.example` → `.env` y rellenado las rutas
tú mismo antes).

La primera vez tarda 1-2 minutos: arranca qBittorrent con credenciales ya
fijadas, luego Radarr/Sonarr/Prowlarr generan su config, y en cuanto los
cuatro responden sanos, `bootstrap` los conecta entre sí y termina solo.
Comprueba que terminó bien con `docker compose logs bootstrap` — deberías
ver `BOOTSTRAP COMPLETADO`.

## 5. Qué es automático y qué queda MANUAL

### Automático (lo hace `bootstrap` sin tocar nada)

- Categorías `movies`/`tv` en qBittorrent, con sus rutas
- qBittorrent conectado como cliente de descargas en Radarr y Sonarr
- Carpetas raíz de la biblioteca configuradas
- Prowlarr conectado con Radarr y Sonarr (sync de indexadores)
- Radarr/Sonarr/Prowlarr sin login (o con el del instalador, `ARR_LOGIN=1`)
- Perfiles de calidad reales de TRaSH Guides (vía Recyclarr) para Radarr
  y Sonarr, en vez de "cualquier calidad vale"
- Perfiles de idioma de Bazarr (`ENGLISH`, `ENGLISH + SPANISH`), conectado
  a Radarr y Sonarr
- Panel (Homer, `http://<IP>:3000`) con tema propio y enlaces a cada app ya
  apuntando a tu IP; Radarr/Sonarr/Prowlarr muestran actividad y avisos en
  vivo, y Jellyfin/Bazarr un punto verde/rojo según respondan
- Página **Espacio en disco** (`http://<IP>:3001`, enlazada en el panel,
  grupo "Sistema"): qué ocupa el disco, qué descargas se han quedado
  fuera de Jellyfin (y se pueden rescatar con una importación manual en
  Radarr/Sonarr) y cuánto espacio "fantasma" hay (descargas que ya no
  forman parte de la biblioteca). Se actualiza sola cada
  `DISK_REPORT_INTERVAL_HOURS` (1 por defecto) o con su botón. El espacio
  fantasma se borra desde la propia página (botón **Borrar** o selección
  múltiple, con confirmación) o con `scripts\borrar-fantasmas.ps1`. Nunca
  se ofrece borrar lo que falta en la biblioteca, lo reciente ni lo
  dudoso, y la biblioteca es de solo lectura para este servicio. Ojo:
  como Radarr/Sonarr, la página no pide contraseña dentro de tu red.
  Lo que se descarga pero se queda fuera de la biblioteca ("Manual
  Import required") se importa solo cuando no hay duda de qué es
  (`DISK_REPORT_AUTO_IMPORT`, activado por defecto); si hay varias
  versiones o un nombre ilegible, la página ofrece un botón **Importar**
  o explica qué hacer. En "Películas/Series que más ocupan", la **✕**
  borra esa película o serie **definitivamente**: de Radarr/Sonarr (no
  se vuelve a descargar), del disco (biblioteca y descarga), de Jellyfin
  y de Seerr (se puede volver a pedir). Radarr/Sonarr no tienen
  papelera: lo que se borra o se sustituye por una versión mejor se
  elimina al momento
- **Tarjeta "Disco" en el panel** (debajo de los servicios): la misma
  barra de la página Espacio en disco, con un botón **Parar descargas /
  Reanudar descargas**. Para todo lo que esté en marcha en qBittorrent,
  también lo que comparte (no hace que Radarr/Sonarr lo borren antes de
  tiempo), y "Reanudar" lo deja todo como estaba, sin arrancar nunca un
  torrent que hayas parado tú. Si quedan menos de
  `DISK_MIN_FREE_GB` libres (50 por defecto) las descargas se paran
  solas, y se reanudan solas al volver a haber 20 GB más (una pausa
  manual nunca se deshace sola). La página Espacio en disco lista
  además las **descargas atascadas** (sin fuentes más de
  `STALLED_HOURS`, 6 por defecto), con un botón para descartarlas:
  Radarr/Sonarr las ponen en su lista negra y buscan otra versión
- (Opcional) Radarr/Sonarr → Jellyfin Connect, en cuanto pegues
  `JELLYFIN_API_KEY` en `.env` y relances bootstrap — ver tabla de abajo

### Manual, obligatorio (no se puede automatizar de forma segura)

Guía paso a paso, en orden, con capturas de dónde hacer clic:
[`CONFIGURACION-MANUAL.md`](CONFIGURACION-MANUAL.md).

| Tarea | Dónde | Por qué no se automatiza |
|---|---|---|
| Añadir tus indexadores/trackers | Prowlarr `:9696` → Indexers → Add | Requieren tus credenciales privadas; en cuanto los añadas se empujan solos a Radarr/Sonarr |
| Asistente inicial (usuario admin + bibliotecas `/data/media/movies` y `/data/media/tv`) | Jellyfin `:8096` | Crear el admin implica fijar una contraseña tuya; mejor la pones tú en el asistente |
| (Opcional) Pegar `JELLYFIN_API_KEY` en `.env` para que Radarr/Sonarr avisen a Jellyfin al importar | — | La API key de Jellyfin no existe hasta generarla tú tras el asistente inicial; sin esto, Jellyfin depende solo de su monitorización en tiempo real (poco fiable vía WSL2) para detectar contenido nuevo |
| Asistente inicial (login con el admin de Jellyfin, conectar Radarr/Sonarr con sus API keys) | Seerr `:5055` | Depende de que el admin de Jellyfin ya exista |
| Elegir proveedor de subtítulos | Bazarr `:6767` → Settings → Providers | Requiere una cuenta externa (p.ej. OpenSubtitles.com); la conexión a Radarr/Sonarr ya la hace `bootstrap` |
| Cambiar la contraseña por defecto | qBittorrent `:8080` (admin/adminadmin) | Viene fijada para que `bootstrap` pueda usarla desde el primer arranque; cámbiala tú tras el primer login |

## 6. Login / acceso sin contraseña

- **Radarr, Sonarr, Prowlarr**: `bootstrap` los deja sin login (método
  *External*): entras directo, sin usuario/contraseña. Si prefieres que
  pidan login, pon `ARR_LOGIN=1` en `.env` junto a `MC_USER`/`MC_PASSWORD`
  (el instalador lo pregunta y usa el mismo usuario que Jellyfin) y vuelve
  a lanzar `bootstrap`. Ninguno de sus puertos se abre en el router.
- **Jellyfin**: no tiene un modo "sin login" real. Lo más parecido: crea,
  además de tu cuenta admin, un segundo usuario con **contraseña en
  blanco** (Dashboard → Users → Add User, deja el campo contraseña vacío).
  En el móvil/TV solo tocas ese perfil, sin teclear nada.
- **Seerr**: por diseño necesita saber quién solicita cada cosa (cuotas,
  permisos, notificaciones), así que su pantalla de login no se puede
  quitar de forma soportada. Conéctalo a ese mismo usuario Jellyfin sin
  contraseña: el login se reduce a pulsar "Sign In" sin escribir nada.
- **qBittorrent**: usuario `admin` / contraseña `adminadmin` fijada por
  `bootstrap/qbt-seed.sh`. **Cámbiala** desde la WebUI en tu primer login
  (Tools → Options → Web UI) — el resto del stack ya la conoce, así que si
  la cambias, actualiza también el download client en Radarr/Sonarr, y
  pon `QBT_PASS=<la nueva>` en `.env` para la página Espacio en disco
  (sin ella sale igual, pero sin saber qué sigue cargado en qBittorrent).

## 7. Móvil y TV (webOS)

Usa siempre `http://<HOST_LAN_IP>:<puerto>` (no `localhost`) desde el móvil
o la tele — son otros dispositivos en la misma LAN. El panel
(`http://<HOST_LAN_IP>:3000`) ya centraliza todos los enlaces con la IP
correcta. Jellyfin tiene apps oficiales para Android/iOS y para LG webOS
(búscala como "Jellyfin" en la LG Content Store); Seerr se usa desde el
navegador del móvil (no tiene app nativa).

### "No me carga desde el móvil aunque he copiado bien la IP"

Antes de sospechar de Docker/el PC, comprueba esto **desde el propio
PC**: abre `http://<HOST_LAN_IP>:3000` (con la IP, no `localhost`) en un
navegador del propio PC. Si ahí sí carga, el stack y el firewall de
Windows están bien (Docker Desktop ya trae reglas de firewall que
permiten esto incluso si la red está clasificada como "Pública") — el
problema está entre el móvil y el PC, no en el stack. En ese caso,
revisa en este orden:

1. **¿El móvil está en la misma WiFi, no en datos móviles?**
2. **¿Es la WiFi principal, o una red de invitados/IoT separada?**
   Muchos routers traen una red de invitados que aísla dispositivos
   entre sí aunque tenga un nombre parecido a la principal.
3. **Aislamiento de clientes (AP/Client Isolation)** activado en el
   router — opción habitual por defecto en muchos routers, bloquea que
   los dispositivos de la misma WiFi se vean entre sí. Se desactiva en
   la configuración del router.
4. Si el PC va por cable Ethernet y el móvil por WiFi, comprueba que el
   router no los separe en redes distintas (raro, pero pasa en algunos
   sistemas mesh con "red para IoT").

## 8. Backup

Automático, sin pasos manuales: el servicio `backup` (contenedor de
larga duración) copia cada
`BACKUP_INTERVAL_HOURS` horas (por defecto 24) lo único que de verdad
no se puede reconstruir clonando este repo:

- `${CONFIG_ROOT}` completo (Radarr, Sonarr, Prowlarr, Bazarr,
  qBittorrent, Recyclarr, Jellyfin, Seerr, Homer — bases de
  datos, historial, ajustes)
- `.env` (rutas de esta máquina — a propósito no está en git)

`docker-compose.yml`, `bootstrap\` y `scripts\` **no** se copian aquí:
ya están en el propio repo git (con historial completo, además), así
que ese es su backup real.

**No hace falta** incluir `data\media` ni `data\torrents` (las bibliotecas)
— eso se vuelve a descargar si hiciera falta.

**Importante sobre `BACKUP_ROOT`**: para que este backup proteja de
verdad contra un fallo de disco, tiene que apuntar a una unidad
**física distinta** de la de `DATA_ROOT`/`CONFIG_ROOT` — otro disco
interno, un USB permanente, una carpeta de red, o una carpeta
vigilada por un servicio de sync en la nube. Si `BACKUP_ROOT` vive en
el mismo disco que el resto, un fallo de disco se lleva por delante
el origen y la copia a la vez.

**Limitación conocida**: es una copia de ficheros en caliente (`rsync`
sin parar los contenedores primero) — hay un riesgo bajo pero no nulo
de capturar una base de datos SQLite a medio escribir. Se ha preferido
disponibilidad continua del stack a backups perfectos; para
recuperarse de eso bastaría con reiniciar la app afectada tras
restaurar.

Verifica que el backup está corriendo: `${BACKUP_ROOT}/.last-backup`
tiene la fecha/hora de la última copia completada.

## 9. Gestión

| Acción | Comando | Script |
|---|---|---|
| Instalar desde cero (interactivo, arranca todo) | — | `scripts\install.ps1` |
| Iniciar | `docker compose up -d` | `scripts\start.ps1` |
| Detener | `docker compose down` | `scripts\stop.ps1` |
| Reiniciar | `docker compose restart` | `scripts\restart.ps1` |
| Estado | `docker compose ps` | `scripts\status.ps1` |
| Actualizar | `docker compose pull && docker compose up -d` | — |
| Re-ejecutar el auto-cableado (p. ej. tras borrar configs) | `docker compose up -d --force-recreate bootstrap` | — |
| Cambiar el modo de consumo de recursos (Mínimo/Default/Rendimiento) | — | `scripts\set-mode.ps1 -Mode <Minimo\|Default\|Rendimiento>` |

Sobre `set-mode.ps1`: ajusta en caliente los límites de qBittorrent
(subida en seeding, descargas/subidas activas, hilos de hashing) y
prepara el techo de memoria de WSL2 en `.wslconfig` — este último paso
**no se aplica solo**, avisa de que hace falta `wsl --shutdown` (para
todo el stack unos segundos) y lo deja para que lo ejecutes cuando te
venga bien. Detalle de los tres perfiles en
`development/specs/archive/016-selector-modos-recursos.md`.

## 10. Remuxes y 4K: disponibles, pero solo si TÚ los eliges

`bootstrap` deja creados en Radarr **dos perfiles de calidad** (vía
Recyclarr, sincronizados desde [TRaSH Guides](https://trash-guides.info)):

| Perfil | Qué descarga | Cuándo se usa |
|---|---|---|
| **HD Bluray + WEB** | 1080p, tamaño acotado | Por defecto, al añadir una película |
| **Remux + WEB 2160p** | Remux / 4K sin recortar | Solo si tú lo seleccionas |

Radarr nunca mezcla ambos automáticamente: el perfil se asigna **por
película**. Sonarr usa un único perfil por ahora — si quieres 4K/remux bajo
demanda también en series, dímelo y lo añado igual que en Radarr (Recyclarr
necesita las referencias exactas de TRaSH para series, no las he adivinado).

**Aplicar cambios en `recyclarr.yml` a mano** (si lo editas tú más adelante):

```powershell
docker compose run --rm recyclarr sync radarr
```

## 11. Reglas de este proyecto (para futuras sesiones)

- No incluir Lidarr ni gestión musical.
- Prowlarr solo gestiona indexadores, nada más.
- No exponer nada a Internet salvo que se pida explícitamente.
- No hardcodear rutas de Windows en `docker-compose.yml`, todo vía `.env`.
- No borrar configuración existente sin backup previo.
