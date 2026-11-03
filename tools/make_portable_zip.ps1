# Packages the built application directory into the versioned portable
# zip (issue #9, revised by ADR-0010 / issue #42): single top-level
# directory (family layout, matches taskly/shuttle), optional extra
# files (README.txt, launcher) injected at the top-directory root,
# SHA256SUMS.txt and per-file .sha256 checksums. Used identically by CI
# and locally, and every zip entry carries a fixed timestamp, so
# rebuilding from the same inputs reproduces the artifact byte-for-byte
# on the same toolchain.
#
# Usage:
#   pwsh tools/make_portable_zip.ps1 -AppDir dist/staging/fileboundary-windows-x64 `
#       -Version 0.2.1 -OutDir dist/release `
#       [-TopDirName FileBoundary-windows-x64] `
#       [-ExtraDir tools/portable]
# Produces:
#   dist/release/fileboundary-<version>-windows-x64.zip
#   dist/release/SHA256SUMS.txt
#   dist/release/<asset>.sha256           (one sidecar per asset)
param(
  [Parameter(Mandatory = $true)][string]$AppDir,
  [Parameter(Mandatory = $true)][string]$Version,
  [Parameter(Mandatory = $true)][string]$OutDir,
  [string]$TopDirName = 'fileboundary-windows-x64',
  # every file in this directory is injected at the zip top-directory
  # root (README.txt, launcher, ...); a single path - no list syntax,
  # so invocation is identical from bash, -File and native pwsh
  [string]$ExtraDir = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$extraFiles = @()
if ($ExtraDir) {
  if (!(Test-Path $ExtraDir -PathType Container)) { throw "ExtraDir not found: $ExtraDir" }
  $extraFiles = @(Get-ChildItem -LiteralPath $ExtraDir -File | Sort-Object Name | ForEach-Object { $_.FullName })
}

if (!(Test-Path (Join-Path $AppDir 'RivetHost.exe'))) {
  throw "AppDir does not look like a built package (missing RivetHost.exe): $AppDir"
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$name = "fileboundary-$Version-windows-x64"
$zipPath = Join-Path $OutDir "$name.zip"

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Fixed timestamp (1980-01-01 00:00:00, the zip epoch) so entry metadata
# does not leak build time and rebuilds are byte-stable.
$fixedTimestamp = [datetime]::new(1980, 1, 1, 0, 0, 0, [datetimekind]::Utc)

if (Test-Path $zipPath) { Remove-Item -LiteralPath $zipPath }
$fs = [System.IO.File]::Open($zipPath, [System.IO.FileMode]::CreateNew)
$archive = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
try {
  $files = Get-ChildItem -LiteralPath $AppDir -Recurse -File | Sort-Object FullName
  foreach ($file in $files) {
    # manual relative path: [System.IO.Path]::GetRelativePath is missing
    # on Windows PowerShell 5.1 (.NET Framework) and this script runs
    # both locally and on CI
    $root = (Resolve-Path $AppDir).Path
    if (!$root.EndsWith('\')) { $root += '\' }
    $rel = $file.FullName.Substring($root.Length).Replace('\', '/')
    $entry = $archive.CreateEntry("$TopDirName/$rel", [System.IO.Compression.CompressionLevel]::Optimal)
    $entry.LastWriteTime = $fixedTimestamp
    $es = $entry.Open()
    try {
      $in = [System.IO.File]::OpenRead($file.FullName)
      try { $in.CopyTo($es) } finally { $in.Dispose() }
    } finally { $es.Dispose() }
  }
  foreach ($extra in $extraFiles) {
    if (!(Test-Path $extra)) { throw "ExtraFile not found: $extra" }
    $entry = $archive.CreateEntry("$TopDirName/$(Split-Path -Leaf $extra)", [System.IO.Compression.CompressionLevel]::Optimal)
    $entry.LastWriteTime = $fixedTimestamp
    $es = $entry.Open()
    try {
      $in = [System.IO.File]::OpenRead((Resolve-Path $extra).Path)
      try { $in.CopyTo($es) } finally { $in.Dispose() }
    } finally { $es.Dispose() }
  }
} finally {
  $archive.Dispose()
  $fs.Dispose()
}

function Get-AssetSha256([string]$Path) {
  (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# SHA256SUMS.txt covers every release asset in OutDir (sha256sum format:
# "<hash>  <name>", two spaces), so consumers can `sha256sum -c` it.
$sums = New-Object System.Collections.Generic.List[string]
Get-ChildItem -LiteralPath $OutDir -File |
  Where-Object { $_.Name -ne 'SHA256SUMS.txt' -and $_.Name -notmatch '\.sha256$' } |
  Sort-Object Name | ForEach-Object {
    $hash = Get-AssetSha256 $_.FullName
    $sums.Add("$hash  $($_.Name)")
    # per-file sidecar: "<hash>" only, file named "<asset>.sha256"
    Set-Content -LiteralPath (Join-Path $OutDir "$($_.Name).sha256") -Value $hash -NoNewline -Encoding ascii
  }
$sumsPath = Join-Path $OutDir 'SHA256SUMS.txt'
Set-Content -LiteralPath $sumsPath -Value $sums -Encoding ascii

Write-Output "Packaged $zipPath ($TopDirName/)"
Write-Output "Wrote $sumsPath with $($sums.Count) entries"
