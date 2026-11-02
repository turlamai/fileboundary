# Post-packaging smoke test (issue #9). Verifies the release artifacts
# from a clean environment: the portable zip extracts and its checksum
# matches, the packaged GUI executable boots, the source distribution's
# CLI emits valid JSON envelopes (version/doctor), and the update-channel
# full package applies into a clean install root.
#
# Usage:
#   pwsh tools/release_smoke.ps1 -Version 0.2.1 `
#       -SourceDir <repo-root> `
#       -PortableZip dist/release/FileBoundary-v0.2.1-windows-x86_64.zip `
#       -FullPackage dist/release/fileboundary-v0.2.1-windows-x86_64-full.zip `
#       -Manifest dist/release/manifest.json
param(
  [Parameter(Mandatory = $true)][string]$Version,
  [Parameter(Mandatory = $true)][string]$SourceDir,
  [Parameter(Mandatory = $true)][string]$PortableZip,
  [Parameter(Mandatory = $true)][string]$FullPackage,
  [Parameter(Mandatory = $true)][string]$Manifest
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SourceDir = (Resolve-Path $SourceDir).Path
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("fb-smoke." + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work | Out-Null

function Assert-True([bool]$Condition, [string]$Message) {
  if (!$Condition) { throw "SMOKE FAILED: $Message" }
}

try {
  # --- 1. portable zip: clean-directory extract + checksum verify ---
  $extract = Join-Path $work 'portable'
  New-Item -ItemType Directory -Path $extract | Out-Null
  Expand-Archive -LiteralPath $PortableZip -DestinationPath $extract
  $expected = (Get-Content "$PortableZip.sha256" -Raw).Trim()
  $actual = (Get-FileHash -LiteralPath $PortableZip -Algorithm SHA256).Hash.ToLowerInvariant()
  Assert-True ($expected -eq $actual) "portable zip sha256 mismatch: $actual"

  $exe = Join-Path $extract 'RivetHost.exe'
  Assert-True (Test-Path $exe) "RivetHost.exe missing from portable zip"
  Assert-True (Test-Path (Join-Path $extract 'THIRD_PARTY_NOTICES.md')) "THIRD_PARTY_NOTICES.md missing from portable zip"

  # --- 2. GUI boot probe: the packaged app starts and stays alive ---
  $proc = Start-Process -FilePath $exe -WorkingDirectory $extract -PassThru
  Start-Sleep -Seconds 20
  Assert-True (!$proc.HasExited) "RivetHost.exe exited during boot probe (exit code $($proc.ExitCode))"
  Stop-Process -Id $proc.Id -Force
  Write-Output 'smoke: portable zip extract + GUI boot probe OK'

  # --- 3. source CLI: version + doctor emit valid JSON envelopes ---
  $env:FILEBOUNDARY_BUILD_COMMIT = 'smoke'
  $versionJson = & racket (Join-Path $SourceDir 'src/cli.rkt') version | Out-String
  $versionEnvelope = $versionJson | ConvertFrom-Json
  Assert-True ($versionEnvelope.status -eq 'ok') "CLI version envelope status: $($versionEnvelope.status)"
  Assert-True ($versionEnvelope.data.version -like "$Version*") "CLI version '$($versionEnvelope.data.version)' does not match release $Version"

  $doctorJson = & racket (Join-Path $SourceDir 'src/cli.rkt') doctor | Out-String
  $doctorEnvelope = $doctorJson | ConvertFrom-Json
  Assert-True ($doctorEnvelope.schemaVersion -eq '1.0') "doctor envelope schemaVersion: $($doctorEnvelope.schemaVersion)"
  Assert-True ($null -ne $doctorEnvelope.data) "doctor envelope has no data"
  Write-Output "smoke: CLI version $($versionEnvelope.data.version) + doctor envelopes OK"

  # --- 4. update channel: full package applies into a clean root ---
  $root = Join-Path $work 'install-root'
  New-Item -ItemType Directory -Path $root | Out-Null
  $applyJson = & racket (Join-Path $SourceDir 'src/cli.rkt') update apply --package $FullPackage --manifest $Manifest --root $root | Out-String
  $applyEnvelope = $applyJson | ConvertFrom-Json
  Assert-True ($applyEnvelope.status -eq 'ok') "update apply failed: $($applyEnvelope.errors | ConvertTo-Json -Compress)"
  Assert-True (Test-Path (Join-Path $root 'current.txt')) "apply did not create the current.txt marker"
  $current = (Get-Content (Join-Path $root 'current.txt') -Raw).Trim()
  Assert-True ($current -eq $Version) "current.txt is '$current', expected $Version"
  Write-Output "smoke: update apply into clean root -> $current OK"

  Write-Output "SMOKE PASSED for v$Version"
} finally {
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
