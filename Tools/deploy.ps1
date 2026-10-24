<#
    deploy.ps1 - Copy NodeRadar (and optionally NodeRadarProbe) into the Forever AddOns folder.

    The repo keeps "## Version: @project-version@" for the packager; the deployed
    copy gets "dev". The repo copy is never modified. (GlassMail's deploy, without
    the embedded library.)

    Usage:
        pwsh Tools/deploy.ps1               # NodeRadar
        pwsh Tools/deploy.ps1 -Probe        # ...and NodeRadarProbe
        pwsh Tools/deploy.ps1 -ProbeOnly    # just NodeRadarProbe

    NodeRadarProbe is a ForeverProbe module, so -Probe and -ProbeOnly deploy the
    ForeverProbe checkout first ($env:FOREVERPROBE, else ..\ForeverProbe).
        pwsh Tools/deploy.ps1 -AddOnsPath "D:\...\_forever_\Interface\AddOns"

    Until the port (#3), deploy the probe alone (-ProbeOnly): v1's NodeRadar.lua
    reads APIs Forever no longer has.
#>

param(
    [string]$AddOnsPath = "C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns",
    [switch]$Probe,
    [switch]$ProbeOnly
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path $AddOnsPath)) { Write-Error "AddOns path not found: $AddOnsPath"; exit 1 }

$ForeverProbe = if ($env:FOREVERPROBE) { $env:FOREVERPROBE } else { Join-Path (Split-Path -Parent $RepoRoot) "ForeverProbe" }

function Deploy-Addon {
    $dest = Join-Path $AddOnsPath "NodeRadar"
    Write-Host "Deploying NodeRadar -> $dest" -ForegroundColor Cyan
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    # The TOC is the list of what ships.
    $lua = @(Get-Content -LiteralPath (Join-Path $RepoRoot "NodeRadar.toc") | ForEach-Object { $_.Trim() } |
        Where-Object { $_ -notmatch "^#" -and $_ -match "[.]lua$" })
    # Our own textures and sound ship too (Media\*.tga, *.ogg: Tools\make_media.py's).
    $media = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot "Media") -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in ".tga", ".ogg" } | ForEach-Object { "Media\" + $_.Name })
    # The key binding (found by its name, not in the TOC) and the libraries' licences, as the package has
    # them (#46).
    $extra = @("Bindings.xml", "Libs\LibStub\LICENSE.txt", "Libs\CallbackHandler-1.0\LICENSE.txt",
        "Libs\LibDBIcon-1.0\LICENSE.txt")
    $files = @("NodeRadar.toc", "LICENSE") + $extra + $lua + $media
    foreach ($f in $files) {
        $src = Join-Path $RepoRoot $f
        $to = Join-Path $dest $f
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $to) | Out-Null
        if ($f -like "*.toc") {
            (Get-Content -LiteralPath $src -Raw) -replace '## Version: @project-version@', '## Version: dev' |
                Set-Content -LiteralPath $to -NoNewline
        } else {
            Copy-Item -LiteralPath $src -Destination $to -Force
        }
        Write-Host "  $f"
    }
    # A Lua file removed from the repo must not linger where the client finds it.
    $keep = $files | ForEach-Object { $_.Replace("/", "\") }
    Get-ChildItem -LiteralPath $dest -File -Recurse | ForEach-Object {
        $rel = $_.FullName.Substring($dest.Length + 1)
        if ($keep -notcontains $rel) {
            Write-Host "  removing stale $rel" -ForegroundColor DarkYellow
            Remove-Item -LiteralPath $_.FullName -Force
        }
    }
}

function Deploy-Probe {
    # The host first: NodeRadarProbe has ## Dependencies: ForeverProbe, so
    # without it the client loads no NodeRadarProbe at all.
    if (-not (Test-Path -LiteralPath (Join-Path $ForeverProbe "Tools\deploy.ps1"))) {
        Write-Error "ForeverProbe checkout not found at $ForeverProbe (clone github.com/Spotnick2/ForeverProbe there, or set `$env:FOREVERPROBE)"
        exit 1
    }
    & pwsh -NoProfile -File (Join-Path $ForeverProbe "Tools\deploy.ps1") -AddOnsPath $AddOnsPath
    if ($LASTEXITCODE -ne 0) { Write-Error "ForeverProbe deploy refused; NodeRadarProbe was not touched"; exit 1 }
    $dest = Join-Path $AddOnsPath "NodeRadarProbe"
    Write-Host "Deploying NodeRadarProbe -> $dest" -ForegroundColor Cyan
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Get-ChildItem -LiteralPath (Join-Path $RepoRoot "Tools\NodeRadarProbe") -File | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $dest $_.Name) -Force
        Write-Host "  $($_.Name)"
    }
}

if (-not $ProbeOnly) { Deploy-Addon }
if ($Probe -or $ProbeOnly) { Deploy-Probe }

Write-Host ""
Write-Host "/reload is enough, a brand-new addon folder included." -ForegroundColor Yellow
Write-Host "In game:  /console scriptErrors 1   then   /fp steps nr release   (the probe's lines: /fp)" -ForegroundColor Green
