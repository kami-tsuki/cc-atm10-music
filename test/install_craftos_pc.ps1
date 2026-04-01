param(
    [string]$Version = 'v2.8.3',
    [string]$Destination = (Join-Path $PSScriptRoot '..\.tools\craftos-pc'),
    [switch]$InstallVcRedist
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$root = [System.IO.Path]::GetFullPath($Destination)
$zipPath = Join-Path $root 'CraftOS-PC-Portable-Win64.zip'
$downloadUrl = "https://github.com/MCJack123/craftos2/releases/download/$Version/CraftOS-PC-Portable-Win64.zip"
$vcRedistPath = Join-Path $root 'vc_redist.x64.exe'

New-Item -ItemType Directory -Force -Path $root | Out-Null

Invoke-WebRequest -UseBasicParsing -Uri $downloadUrl -OutFile $zipPath
Expand-Archive -Path $zipPath -DestinationPath $root -Force

if ($InstallVcRedist) {
    Invoke-WebRequest -UseBasicParsing -Uri 'https://aka.ms/vs/17/release/vc_redist.x64.exe' -OutFile $vcRedistPath
    Start-Process -FilePath $vcRedistPath -ArgumentList '/install', '/quiet', '/norestart' -Wait
}

$consoleExe = Join-Path $root 'CraftOS-PC_console.exe'
if (-not (Test-Path $consoleExe)) {
    throw "CraftOS-PC console executable was not found at $consoleExe"
}

Write-Output $consoleExe