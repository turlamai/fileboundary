# Post-packaging smoke test (issue #9, extended by ADR-0010 / issue #42).
# Verifies the release artifacts from a clean environment: the portable
# zip extracts with the required discoverability layout (single top-level
# directory, README.txt, launcher), its checksum matches, the packaged
# GUI executable boots, the MSI installs and uninstalls cleanly, the
# source distribution's CLI emits valid JSON envelopes (version/doctor),
# and the update-channel full package applies into a clean install root.
#
# Usage:
#   pwsh tools/release_smoke.ps1 -Version 0.2.1 `
#       -SourceDir <repo-root> `
#       -PortableZip dist/release/fileboundary-0.2.1-windows-x64.zip `
#       -MsiPath dist/release/fileboundary-0.2.1-windows-x64.msi `
#       -FullPackage dist/release/fileboundary-0.2.1-windows-x64-update.zip `
#       -Manifest dist/release/manifest.json
param(
  [Parameter(Mandatory = $true)][string]$Version,
  [Parameter(Mandatory = $true)][string]$SourceDir,
  [Parameter(Mandatory = $true)][string]$PortableZip,
  [Parameter(Mandatory = $true)][string]$MsiPath,
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
  # --- 1. portable zip: clean-directory extract + checksum + layout ---
  $extract = Join-Path $work 'portable'
  New-Item -ItemType Directory -Path $extract | Out-Null
  Expand-Archive -LiteralPath $PortableZip -DestinationPath $extract
  $expected = (Get-Content "$PortableZip.sha256" -Raw).Trim()
  $actual = (Get-FileHash -LiteralPath $PortableZip -Algorithm SHA256).Hash.ToLowerInvariant()
  Assert-True ($expected -eq $actual) "portable zip sha256 mismatch: $actual"

  # discoverability layout (ADR-0010): exactly one top-level directory
  # containing README.txt, the launcher and the host exe
  # @() wrapper: a single-entry pipeline yields a scalar and .Count on a
  # scalar string throws under Set-StrictMode
  $topLevel = @(Get-ChildItem -LiteralPath $extract | ForEach-Object { $_.Name })
  Assert-True ($topLevel.Count -eq 1) "portable zip must contain exactly one top-level entry, found: $($topLevel -join ', ')"
  $topDir = Join-Path $extract $topLevel[0]
  Assert-True (Test-Path $topDir -PathType Container) "top-level entry is not a directory"
  Assert-True (Test-Path (Join-Path $topDir 'RivetHost.exe')) "RivetHost.exe missing from portable zip"
  Assert-True (Test-Path (Join-Path $topDir 'README.txt')) "README.txt missing from portable zip (discoverability)"
  Assert-True (Test-Path (Join-Path $topDir 'FileBoundary.cmd')) "FileBoundary.cmd launcher missing from portable zip"
  Assert-True (Test-Path (Join-Path $topDir 'THIRD_PARTY_NOTICES.md')) "THIRD_PARTY_NOTICES.md missing from portable zip"

  # --- 2. GUI boot probe: the packaged app starts and stays alive ---
  $proc = Start-Process -FilePath (Join-Path $topDir 'RivetHost.exe') -WorkingDirectory $topDir -PassThru
  Start-Sleep -Seconds 20
  Assert-True (!$proc.HasExited) "RivetHost.exe exited during boot probe (exit code $($proc.ExitCode))"
  Stop-Process -Id $proc.Id -Force
  Write-Output 'smoke: portable zip layout + GUI boot probe OK'

  # --- 3. MSI: silent install, shortcut + exe land, clean uninstall ---
  $msi = (Resolve-Path $MsiPath).Path
  $msiExpected = (Get-Content "$MsiPath.sha256" -Raw).Trim()
  $msiActual = (Get-FileHash -LiteralPath $msi -Algorithm SHA256).Hash.ToLowerInvariant()
  Assert-True ($msiExpected -eq $msiActual) "msi sha256 mismatch: $msiActual"
  $installLog = Join-Path $work 'msi-install.log'
  $uninstallLog = Join-Path $work 'msi-uninstall.log'
  $p1 = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart /l*v `"$installLog`"" -Wait -PassThru
  Assert-True ($p1.ExitCode -eq 0) "msiexec install failed with exit code $($p1.ExitCode) (log: $installLog)"
  # rivet's WiX authoring names INSTALLFOLDER after the project `name`
  # field (lowercase `fileboundary`); the Start-menu shortcut uses the
  # display name
  $installDir = Join-Path ${env:ProgramFiles} 'fileboundary'
  Assert-True (Test-Path (Join-Path $installDir 'RivetHost.exe')) "MSI did not install RivetHost.exe under $installDir"
  $startMenu = Join-Path ${env:ProgramData} 'Microsoft\Windows\Start Menu\Programs'
  $shortcut = Get-ChildItem -LiteralPath $startMenu -Recurse -Filter 'FileBoundary*.lnk' -ErrorAction SilentlyContinue
  Assert-True ($null -ne $shortcut) "no FileBoundary Start-menu shortcut after MSI install"
  $p2 = Start-Process msiexec.exe -ArgumentList "/x `"$msi`" /qn /norestart /l*v `"$uninstallLog`"" -Wait -PassThru
  Assert-True ($p2.ExitCode -eq 0) "msiexec uninstall failed with exit code $($p2.ExitCode) (log: $uninstallLog)"
  Assert-True (!(Test-Path (Join-Path $installDir 'RivetHost.exe'))) "RivetHost.exe still present after MSI uninstall"
  Write-Output 'smoke: MSI install + Start-menu shortcut + clean uninstall OK'

  # --- 4. source CLI: version + doctor emit valid JSON envelopes ---
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

  # --- 5. update channel: full package applies into a clean root ---
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
  # best-effort uninstall if a later step aborted after the install
  $msiPathResolved = $null
  try { $msiPathResolved = (Resolve-Path $MsiPath -ErrorAction SilentlyContinue).Path } catch {}
  if ($msiPathResolved) {
    Start-Process msiexec.exe -ArgumentList "/x `"$msiPathResolved`" /qn /norestart" -Wait -ErrorAction SilentlyContinue | Out-Null
  }
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
