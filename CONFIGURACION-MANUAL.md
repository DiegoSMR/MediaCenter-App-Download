# Configuración manual — paso a paso, en orden

Todo lo que `bootstrap` no puede hacer por ti (porque requiere una decisión o
una credencial tuya). Sigue el orden: cada paso depende del anterior.

Sustituye `<IP>` por tu `HOST_LAN_IP` (revisa `.env`, por defecto la IP LAN
del PC que ejecuta Docker).

---

## Paso 1 — Prowlarr: añadir indexadores

`http://<IP>:9696`

Con **un único indexador público, The Pirate Bay, es suficiente** para que
el stack funcione — es con el que se ha probado todo este proyecto, y no
pide cuenta ni API key.

1. Menú izquierdo → **Indexers** → botón **Add Indexer** (`+`).
2. En el buscador escribe **"The Pirate Bay"** y haz clic en su tarjeta.
3. No hay usuario ni contraseña que rellenar. Deja marcadas **Enable RSS**,
   **Enable Automatic Search** y **Enable Interactive Search** (vienen
   activadas por defecto).
4. Categorías: deja las que vienen seleccionadas (ya incluyen películas y
   series).
5. Pulsa **Test** (debe salir un check verde) y luego **Save**.
6. No hace falta nada más: Prowlarr ya está conectado a Radarr y Sonarr
   (`bootstrap` lo hizo), así que cada indexador que añadas aquí se empuja
   solo a ambos automáticamente (**App Sync** → *Full Sync*, ya activado).

Verificación: en **Indexers**, la columna de estado del indexador debe estar
en verde.

**¿Más fiabilidad?** Si te encuentras a menudo con releases rechazados por
"Not enough seeders" (0 seeders = torrent muerto, nadie de quien
descargar), puedes añadir más indexadores igual que este — sobre todo
trackers privados, que suelen tener mejor disponibilidad, aunque piden
registro/invitación. No hace falta para empezar.

---

## Paso 2 — Jellyfin: asistente inicial + bibliotecas

`http://<IP>:8096`

1. **Idioma preferido** → el que quieras → Next.
2. **Crear la cuenta admin**: usuario + contraseña. Esta la eliges tú, no la
   generamos nosotros (por eso este paso es manual).
3. **Configurar bibliotecas** → Add Media Library:
   - Content type: **Movies** → Folder: `/data/media/movies`
   - Add Media Library otra vez → Content type: **Shows** → Folder:
     `/data/media/tv`
4. **Metadata language** → el que prefieras → Next.
5. **Remote access**: como el stack es solo-LAN, puedes dejar "Allow remote
   connections" desactivado (más simple y coherente con no exponer nada a
   Internet).
6. Finish.

### Paso 2b — Usuario sin contraseña (para el móvil/TV)

1. Dashboard (icono de engranaje) → **Users** → **Add User**.
2. Nombre del usuario (p. ej. `familia`), deja el campo **contraseña en
   blanco**, guarda.
3. En el móvil/TV, al abrir la app de Jellyfin y seleccionar el servidor,
   toca ese perfil — no pide contraseña.

---

## Paso 2c — Conectar Radarr/Sonarr a Jellyfin (para que la biblioteca se actualice sola)

Sin esto, Jellyfin depende de su monitorización en tiempo real
(`EnableRealtimeMonitor`) para detectar películas/episodios nuevos —
poco fiable sobre el bind mount de Windows vía WSL2 (protocolo `9p`,
no un filesystem Linux nativo; los eventos de "archivo nuevo" no
siempre llegan). Con esta conexión, Radarr/Sonarr le dicen a Jellyfin
explícitamente "actualiza tu biblioteca" en cuanto importan algo — no
depende de que Jellyfin se entere solo.

Solo el primer paso (generar la key) es manual — no existe hasta que
completas el asistente inicial de Jellyfin. El resto (crear la conexión
en Radarr y Sonarr) lo hace `bootstrap` solo en cuanto la tiene.

1. Jellyfin (`http://<IP>:8096`) → Dashboard (engranaje) → **API Keys**
   → botón `+` → nombre cualquiera (p. ej. "Radarr-Sonarr") → genera y
   copia la key.
2. Pégala en tu `.env` como `JELLYFIN_API_KEY=...` y vuelve a lanzar
   bootstrap: `docker compose run --rm recyclarr sync` (o
   `docker compose up -d --force-recreate bootstrap`).

Verificación: importa algo nuevo (o pulsa **Trigger Search** en un
episodio/película que ya tengas) y comprueba que aparece en Jellyfin
sin tener que esperar a su escaneo periódico ni forzarlo tú a mano.

---

## Paso 3 — Seerr: asistente inicial + conectar Radarr/Sonarr

`http://<IP>:5055`

Necesita que el **paso 2 ya esté hecho** (usa el admin de Jellyfin para
iniciar sesión).

1. Idioma → Next.
2. **Connect to Jellyfin**:
   - URL: `http://jellyfin:8096` (nombre de servicio, no `localhost` ni la IP)
   - Inicia sesión con el usuario **admin** que creaste en el paso 2.
3. Selecciona qué bibliotecas de Jellyfin sincronizar (Movies y Shows).
4. **Configurar Radarr**:
   - Settings → Services → **Add Radarr Server**
   - Hostname: `radarr` — Port: `7878`
   - API Key: cópiala de Radarr (`http://<IP>:7878` → Settings → General →
     Security → API Key).
   - Root Folder: `/data/media/movies`
   - Quality Profile: `HD Bluray + WEB` (o `Remux + WEB 2160p` si esa
     petición la quieres siempre en 4K)
   - Marca **Default Server**.
5. **Configurar Sonarr**: igual que Radarr pero:
   - Hostname: `sonarr` — Port: `8989`
   - Root Folder: `/data/media/tv`
   - Quality Profile: la única disponible por ahora.
   - Marca **Default Server**.

Verificación: busca una película o serie desde Seerr y pulsa
"Request" — debería aparecer en Radarr/Sonarr en segundos.

---

## Paso 4 — Bazarr: elegir proveedor de subtítulos

`http://<IP>:6767`

Los perfiles de idioma (`ENGLISH`, `ENGLISH + SPANISH`) y la conexión a
Radarr/Sonarr ya los hace `bootstrap` solo — aquí solo queda elegir de
dónde saca los subtítulos (requiere una cuenta externa, eso sí es
manual).

1. Settings → **Providers** → añade un proveedor de subtítulos (ver abajo).
2. Guarda. Bazarr empezará a buscar subtítulos para lo que ya tengas en las
   bibliotecas de Radarr/Sonarr.

### Proveedor recomendado: OpenSubtitles.com

Con este solo es suficiente para que Bazarr encuentre subtítulos en la
mayoría de idiomas.

1. Crea una cuenta gratuita en [opensubtitles.com](https://www.opensubtitles.com)
   (botón *Register*, es gratis).
2. Bazarr → Settings → **Providers** → **Add Provider**.
3. Selecciona **"OpenSubtitles.com"** (ojo: no ".org" — es un proveedor
   distinto y más antiguo que Bazarr también lista aparte).
4. Introduce el usuario/email y la contraseña de la cuenta que acabas de
   crear.
5. Activa **"Use Hash"** si aparece la opción — hace el emparejamiento de
   subtítulos más preciso (por huella del archivo, no solo por nombre).
6. Guarda.

La cuenta gratuita tiene un límite de descargas de subtítulos al día
(unas 20). Si lo agotas, Bazarr reintentará al día siguiente; si necesitas
más, OpenSubtitles.com tiene planes VIP de pago.

---

## Paso 5 — qBittorrent: cambiar la contraseña por defecto

`http://<IP>:8080` (usuario `admin` / contraseña `adminadmin`)

1. Tools → Options → **Web UI**.
2. Cambia la contraseña.
3. Guarda.
4. **Importante**: si cambias la contraseña, Radarr y Sonarr dejarán de
   poder hablar con qBittorrent hasta que actualices el download client:
   Radarr/Sonarr → Settings → Download Clients → qBittorrent → actualiza la
   contraseña → Test → Save.

---

## Paso 6 — Router: abrir el puerto 6881 (descargas mucho más rápidas)

Sin esto, nadie de fuera puede conectarse a tu qBittorrent: solo bajas de
los pocos que aceptan conexiones, y las descargas van muy lentas aunque
el torrent tenga miles de fuentes. Se hace una vez, en el router.

1. **Entra en el router**: abre `http://192.168.1.1` en el navegador (si no
   carga, prueba `192.168.0.1`). Usuario y contraseña suelen estar en una
   pegatina debajo del router.
2. **Comprueba que tu operadora te da IP pública**. En la página de estado
   del router busca la **IP WAN** (o "IP de Internet"), y en otra pestaña
   busca en Google **"cuál es mi IP"**.
   - Si **coinciden**, sigue al punto 3.
   - Si **no coinciden** (o la IP WAN empieza por `100.64`–`100.127`, `10.`,
     `172.16`–`172.31` o `192.168.`), tu operadora comparte la IP entre
     varios clientes (CGNAT) y abrir el puerto no servirá. Llama y pide
     **"una IP pública, salir del CGNAT"**; muchas lo hacen gratis.
3. **Reserva la IP de este PC** para que no cambie: en "DHCP" o "Reserva de
   IP", asigna a este PC la IP que pusiste en `HOST_LAN_IP` (en `.env`).
4. **Crea la regla** en "NAT", "Redirección de puertos", "Port forwarding"
   o "Abrir puertos":
   - Protocolo: **TCP y UDP** (si solo deja uno, haz dos reglas)
   - Puerto externo e interno: **6881**
   - IP del equipo: la de este PC (`HOST_LAN_IP`)
5. **Guarda** (algunos routers piden reiniciar).

El puerto 6881 ya está fijado en qBittorrent y publicado por Docker, y el
firewall de Windows pregunta la primera vez (acepta en redes privadas y
públicas). No hace falta tocar nada más en el PC.

---

## Resumen del orden

```
1. Prowlarr    (indexadores)
2. Jellyfin    (admin + bibliotecas + usuario sin contraseña)
2c. (Opcional) JELLYFIN_API_KEY en .env + relanzar bootstrap -> Connect a Sonarr/Radarr
3. Seerr  (depende de 2 — login admin, conectar Radarr/Sonarr)
4. Bazarr      (elegir proveedor de subtítulos — el resto ya está hecho)
5. qBittorrent (cambiar contraseña por defecto)
6. Router      (abrir el puerto 6881 — descargas mucho más rápidas)
```

Todo lo demás (categorías movies/tv, carpetas raíz, cliente de descargas,
login de Radarr/Sonarr/Prowlarr (sin contraseña, o `ARR_LOGIN=1`), perfiles de
calidad, Bazarr conectado a Radarr/Sonarr) ya está hecho por `bootstrap`
+ `recyclarr`.
