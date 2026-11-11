# Packs ./realFuel into ./realfuel.zip (forward-slash entry names, the game's folders at the top).
# Usage: powershell -ExecutionPolicy Bypass -File build.ps1 [-Install]
#   -Install  also copies the zip into the BeamNG user mods folder
param([switch]$Install)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$root = $PSScriptRoot
$src = Join-Path $root 'realFuel'
$name = 'realfuel.zip'   # same name the BeamNG.Earth add-on installs, so the two never load side by side
$zip = Join-Path $root $name

if (Test-Path $zip) { Remove-Item $zip -Force }

$archive = [System.IO.Compression.ZipFile]::Open($zip, [System.IO.Compression.ZipArchiveMode]::Create)
try {
  Get-ChildItem $src -Recurse -File | ForEach-Object {
    $entry = $_.FullName.Substring($src.Length + 1).Replace('\', '/')
    [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $_.FullName, $entry, [System.IO.Compression.CompressionLevel]::Optimal)
    "  + $entry"
  }
} finally {
  $archive.Dispose()
}
"Built $zip"

if ($Install) {
  $mods = Join-Path $env:LOCALAPPDATA 'BeamNG\BeamNG.drive\current\mods'
  if (-not (Test-Path $mods)) { throw "Mods folder not found: $mods" }
  Copy-Item $zip (Join-Path $mods $name) -Force
  "Installed to $mods\$name"
  Get-ChildItem $mods -Filter 'realFuel*.zip' | Where-Object { $_.Name -ne $name } | ForEach-Object {
    "WARNING: older copy $($_.Name) is still in the mods folder, delete it so the mod does not load twice"
  }
}
