<#
    run.ps1 - Syntax-check the addon and the probe, and run every tests\test_*.lua under Lua 5.1.

    Usage:
        pwsh tests/run.ps1
        pwsh tests/run.ps1 -Lua "C:\path\to\lua5.1.exe"

    The probe's tests load ..\ForeverProbe (or $env:FOREVERPROBE); they run
    only here, never in CI (ForeverProbe is private).
#>

param(
    [string]$Lua = "C:\Program Files (x86)\Lua\5.1\lua.exe"
)

$ErrorActionPreference = "Stop"
if (-not (Test-Path $Lua)) { Write-Error "Lua 5.1 not found at $Lua (pass -Lua <path>)"; exit 1 }
$RepoRoot = Split-Path -Parent $PSScriptRoot

Push-Location $RepoRoot
try {
    # The TOCs are the list, so a new file cannot go unchecked: the addon's
    # and the probe's.
    $luac = Join-Path (Split-Path -Parent $Lua) "luac.exe"
    $tocFiles = @(Get-Content "NodeRadar.toc" | ForEach-Object { $_.Trim() } |
        Where-Object { $_ -notmatch "^#" -and $_ -match "[.]lua$" })
    $probeFiles = @(Get-Content "Tools\NodeRadarProbe\NodeRadarProbe.toc" | ForEach-Object { $_.Trim() } |
        Where-Object { $_ -notmatch "^#" -and $_ -match "[.]lua$" } | ForEach-Object { "Tools\NodeRadarProbe\$_" })
    if (-not (Test-Path $luac)) {
        Write-Host "luac -p SKIPPED: no luac.exe beside $Lua - syntax was NOT checked" -ForegroundColor Yellow
    } else {
        & $luac -p @tocFiles @probeFiles
        if ($LASTEXITCODE -ne 0) { Write-Host "luac -p FAILED" -ForegroundColor Red; exit 1 }
        Remove-Item -LiteralPath "luac.out" -ErrorAction SilentlyContinue
        Write-Host "luac -p: ok ($($tocFiles.Count) addon files + $($probeFiles.Count) probe)" -ForegroundColor DarkGray
    }

    $failed = 0
    Get-ChildItem (Join-Path $PSScriptRoot "test_*.lua") | Sort-Object Name | ForEach-Object {
        Write-Host "-- $($_.Name) " -NoNewline -ForegroundColor Cyan
        & $Lua $_.FullName
        if ($LASTEXITCODE -ne 0) { $failed++ }
    }
    if ($failed -gt 0) { Write-Host "$failed test file(s) FAILED" -ForegroundColor Red; exit 1 }
    Write-Host "All test files passed." -ForegroundColor Green
}
finally { Pop-Location }
