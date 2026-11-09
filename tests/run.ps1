<#
    run.ps1 - Syntax-check the addon and the probe, and run every tests\test_*.lua under Lua 5.1.

    The runner is WowTestKit's, at the commit and the client build tests\kit.pin names
    (cached in %LOCALAPPDATA%\WowTestKit\<sha>; tests\kit.ps1 fetches it).

    Usage:
        pwsh tests/run.ps1
        pwsh tests/run.ps1 -Lua "C:\path\to\lua5.1.exe"
        pwsh tests/run.ps1 -KitDev      # against the ..\WowTestKit working copy, not the pin

    The probe's tests load ..\ForeverProbe (or $env:FOREVERPROBE); they run
    only here, never in CI (ForeverProbe is private).
#>

param(
    [string]$Lua = "C:\Program Files (x86)\Lua\5.1\lua.exe",
    [switch]$KitDev
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "kit.ps1")
$kit = Get-WowTestKit -RepoRoot $RepoRoot -KitDev:$KitDev

# The TOCs are the list, so a new file cannot go unchecked: the addon's (the
# kit reads NodeRadar.toc) and the probe's.
$probeFiles = @(Get-Content (Join-Path $RepoRoot "Tools\NodeRadarProbe\NodeRadarProbe.toc") | ForEach-Object { $_.Trim() } |
    Where-Object { $_ -notmatch "^#" -and $_ -match "[.]lua$" } | ForEach-Object { "Tools\NodeRadarProbe\$_" })

& (Join-Path $kit "scripts\run.ps1") -RepoRoot $RepoRoot -Toc "NodeRadar.toc" -Extra $probeFiles -Lua $Lua
exit $LASTEXITCODE
