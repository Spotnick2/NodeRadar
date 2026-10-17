<#
    export_nodes.ps1 - Merge the nodes your characters learned into Data/Nodes.lua.

    Finds every account's SavedVariables\NodeRadar.lua and hands them to
    Tools/export_nodes.lua, which prints what it would add (with how and on
    which build each name was learned) and any conflict.

    Usage:
        pwsh Tools/export_nodes.ps1            # review
        pwsh Tools/export_nodes.ps1 -Write     # then write Data/Nodes.lua
#>

param(
    [string]$Wtf = "C:\Program Files (x86)\World of Warcraft\_classic_beta_\WTF\Account",
    [string]$Lua = "C:\Program Files (x86)\Lua\5.1\lua.exe",
    [switch]$Write
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path $Lua)) { Write-Error "Lua 5.1 not found at $Lua (pass -Lua <path>)"; exit 1 }
$files = @(Get-ChildItem -Path $Wtf -Filter "NodeRadar.lua" -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.DirectoryName -like "*\SavedVariables" } | ForEach-Object { $_.FullName })
if ($files.Count -eq 0) { Write-Error "no SavedVariables\NodeRadar.lua under $Wtf"; exit 1 }

Push-Location $RepoRoot
try {
    $luaArgs = @("Tools\export_nodes.lua") + $files
    if ($Write) { $luaArgs += "--write" }
    & $Lua @luaArgs
    exit $LASTEXITCODE
}
finally { Pop-Location }
