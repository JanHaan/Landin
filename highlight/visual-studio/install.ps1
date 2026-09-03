param(
    [string]$Destination = (Join-Path $env:USERPROFILE ".vs\Extensions\Landin")
)

$ErrorActionPreference = "Stop"
$Source = Join-Path $PSScriptRoot "..\textmate\syntaxes\landin.tmLanguage.json"
$Syntaxes = Join-Path $Destination "Syntaxes"
New-Item -ItemType Directory -Force -Path $Syntaxes | Out-Null
Copy-Item -Force $Source (Join-Path $Syntaxes "Landin.json")
Write-Host "Installed Landin TextMate grammar in $Destination"
