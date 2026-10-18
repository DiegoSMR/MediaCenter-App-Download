# Extras (specs 035 y 036): busca en torrents\ los extras que Radarr/Sonarr
# no importan (Featurettes, Deleted Scenes...) y los enlaza (hardlink: no
# ocupan mas y el torrent sigue compartiendose) dentro de la carpeta de su
# pelicula o serie, p.ej. media\movies\Lord of War (2005)\featurettes\.
# Jellyfin los enseña en la ficha de la pelicula; Radarr/Sonarr ignoran esas
# subcarpetas, y si se borra la pelicula se van con ella.
#
#   scripts\importar-extras.ps1           lista y pregunta
#   scripts\importar-extras.ps1 -SoloVer  solo lista
#   scripts\importar-extras.ps1 -Si       lo hace sin preguntar
#   scripts\importar-extras.ps1 -DesdePanel <CONFIG_ROOT>
#       boton "Importar extras" del panel: lo lanza scripts\qbt-abrir.cmd
#       (tarea de Windows de cada minuto) si ve el aviso
#       <CONFIG_ROOT>\disk-report\importar-extras; deja el resultado en
#       extras-resultado.json para el panel.
#
# Los enlaces los hace este script en Windows, no un contenedor: un hardlink
# no cruza montajes de Docker, y disk-report no debe poder escribir en la
# biblioteca. El contenedor (extras.py) solo lee y avisa a Jellyfin.
param([switch]$SoloVer, [switch]$Si, [string]$DesdePanel)

# Sin ErrorActionPreference=Stop: en PowerShell 5.1 convertiria en error
# cualquier linea de docker por stderr (la del build), aun con 2>$null.
# UTF-8 para leer bien las tildes de la salida de docker.
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ProjectRoot = Split-Path -Parent $PSScriptRoot

if ($DesdePanel) {
    $stateDir = Join-Path $DesdePanel 'disk-report'
    $flag = Join-Path $stateDir 'importar-extras'
    $running = "$flag.en-curso"
    if (-not (Test-Path -LiteralPath $flag)) { return }  # nada pedido
    Move-Item -LiteralPath $flag -Destination $running -Force
    $Si = $true
}
# Resultado para el panel (spec 036).
$result = @{ ok = $true; linked = 0; failed = 0; owners = @(); message = '' }

Push-Location $ProjectRoot
try {
    $line = Get-Content .env | Where-Object { $_ -match '^DATA_ROOT=' } | Select-Object -First 1
    if (-not $line) { throw 'No encuentro DATA_ROOT en .env' }
    $dataRoot = ($line -split '=', 2)[1].Trim().Trim('"')
    # Ruta del contenedor (/data/...) -> ruta de Windows.
    function ConvertTo-HostPath([string]$p) {
        [IO.Path]::GetFullPath((Join-Path $dataRoot ($p.Substring('/data/'.Length) -replace '/', '\')))
    }
    function Format-Size([double]$b) {
        if ($b -ge 1GB) { '{0:N1} GB' -f ($b / 1GB) } else { '{0:N0} MB' -f ($b / 1MB) }
    }
    # CreateHardLink directo: New-Item -ItemType HardLink falla con nombres con [ ].
    if (-not ('MC.Native' -as [type])) {
        Add-Type -Namespace MC -Name Native -MemberDefinition '
            [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
            public static extern bool CreateHardLink(string lpFileName, string lpExistingFileName, IntPtr lpSecurityAttributes);'
    }

    Write-Host 'Buscando extras en torrents\ ...'
    $out = docker compose --profile tools run --rm --build --entrypoint python3 disk-clean -u /app/extras.py plan 2>$null
    $json = $out | Where-Object { $_ -like 'PLAN:*' } | Select-Object -First 1
    if (-not $json) { throw 'extras.py no ha devuelto nada (mira: docker compose --profile tools run --rm disk-clean)' }
    $plan = $json.Substring(5) | ConvertFrom-Json

    Write-Host ''
    if ($plan.items) {
        Write-Host 'Se enlazan dentro de la carpeta de su película o serie:'
        foreach ($i in $plan.items) {
            $bytes = ($i.links | Measure-Object -Property bytes -Sum).Sum
            Write-Host ("  + {0}  ({1} archivo(s), {2})" -f $i.owner, @($i.links).Count, (Format-Size $bytes))
            foreach ($l in $i.links) { Write-Host ('      ' + $l.dest.Substring($i.folder.Length + 1)) }
        }
    } else {
        Write-Host 'No hay extras nuevos.'
        $result.message = 'No había extras nuevos.'
    }
    if ($plan.unknown) {
        Write-Host 'No se tocan (no se sabe de qué película o serie son):'
        foreach ($u in $plan.unknown) { Write-Host ("  ? {0}: {1}" -f $u.download, $u.reason) }
    }
    if (-not $plan.items -or $SoloVer) { return }

    Write-Host ''
    if (-not $Si) {
        $ans = Read-Host 'Escribe  si  para hacerlo, o Enter para salir sin tocar nada'
        if ("$ans".Trim().ToLower() -notin @('si', 'sí', 's')) { Write-Host 'No se ha tocado nada.'; return }
    }
    $folders = @()
    foreach ($i in $plan.items) {
        foreach ($l in $i.links) {
            $dest = ConvertTo-HostPath $l.dest
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest)) | Out-Null
            if ([MC.Native]::CreateHardLink($dest, (ConvertTo-HostPath $l.src), [IntPtr]::Zero)) { $result.linked++ }
            else {
                $result.failed++
                $err = New-Object ComponentModel.Win32Exception ([Runtime.InteropServices.Marshal]::GetLastWin32Error())
                Write-Host ("  No se ha podido enlazar {0}: {1}" -f (Split-Path -Leaf $dest), $err.Message)
            }
        }
        $folders += $i.folder
        $result.owners += $i.owner
    }
    $result.message = "Importados $($result.linked) extra(s) de: $($result.owners -join ', ')." +
        $(if ($result.failed) { " $($result.failed) no se han podido enlazar." } else { '' })
    Write-Host $result.message
    docker compose --profile tools run --rm --entrypoint python3 disk-clean -u /app/extras.py refresh @folders 2>$null |
        Where-Object { $_ -like 'Jellyfin:*' } | ForEach-Object { Write-Host $_ }
} catch {
    $result.ok = $false
    $result.message = "$_"
    Write-Host "Error: $_"
} finally {
    Pop-Location
    if ($DesdePanel) {
        $result.at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        # UTF-8 sin BOM (Set-Content de PowerShell 5.1 pondria ANSI).
        [IO.File]::WriteAllText((Join-Path $stateDir 'extras-resultado.json'), ($result | ConvertTo-Json -Compress),
            (New-Object Text.UTF8Encoding $false))
        Remove-Item -LiteralPath $running -Force -ErrorAction SilentlyContinue
    }
}
