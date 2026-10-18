@echo off
rem Abre qBittorrent (nativo, spec 013) si el panel lo ha pedido (spec 030).
rem Lo ejecuta la tarea "MediaCenter qBittorrent (panel)" cada minuto, oculta
rem (conhost --headless). Uso: qbt-abrir.cmd <CONFIG_ROOT>
rem El aviso lo escribe disk-report al pulsar "Abrir qBittorrent" y lo borra
rem el mismo cuando qBittorrent ya responde. Lanzar la tarea con qBittorrent
rem ya abierto no hace nada (no se duplica con el mismo perfil).
if exist "%~1\disk-report\abrir-qbittorrent" schtasks /run /tn "MediaCenter qBittorrent" >nul 2>&1
rem Boton "Importar extras" del panel (spec 036): mismo mecanismo, otro aviso.
if exist "%~1\disk-report\importar-extras" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0importar-extras.ps1" -DesdePanel "%~1" >nul 2>&1
rem Actualizar MediaCenter mismo (spec 051): mismo mecanismo; el script lanza
rem su propia tarea ("MediaCenter actualizar programa", sin limite).
if exist "%~1\disk-report\actualizar-mediacenter" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0actualizar-mediacenter.ps1" -Lanzar "%~1" >nul 2>&1
rem Actualizaciones de las apps (spec 042): mismo mecanismo. Buscar o
rem actualizar tarda mas que el minuto de esta tarea, asi que el script solo
rem lanza su propia tarea ("MediaCenter actualizaciones", sin limite).
if exist "%~1\disk-report\actualizar" goto actualizaciones
if exist "%~1\disk-report\buscar-actualizaciones" goto actualizaciones
exit /b 0
:actualizaciones
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0actualizaciones.ps1" -Lanzar "%~1" >nul 2>&1
