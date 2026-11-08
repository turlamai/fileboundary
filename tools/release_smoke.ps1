# Post-packaging smoke test (issue #9, extended by ADR-0010 / issue #42;
# update channel switched to the signed feed by ADR-0011). Verifies the
# release artifacts from a clean environment: the portable zip extracts
# with the required discoverability layout (single top-level directory,
# README.txt, launcher), its checksum matches, the packaged GUI executable
# boots, the MSI installs and uninstalls cleanly, the source distribution's
# CLI emits valid JSON envelopes (version/doctor), and the signed update
# feed parses as the rivet wrapper with matching artifact URLs.
#
# Usage:
#   pwsh tools/release_smoke.ps1 -Version 0.2.1 `
#       -SourceDir <repo-root> `
#       -PortableZip dist/release/fileboundary-0.2.1-windows-x64.zip `
#       -MsiPath dist/release/fileboundary-0.2.1-windows-x64.msi `
#       -UpdateManifest dist/release/update-stable.json
param(
  [Parameter(Mandatory = $true)][string]$Version,
  [Parameter(Mandatory = $true)][string]$SourceDir,
  [Parameter(Mandatory = $true)][string]$PortableZip,
  [Parameter(Mandatory = $true)][string]$MsiPath,
  [Parameter(Mandatory = $true)][string]$UpdateManifest
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

  # --- 5. signed update feed: rivet wrapper shape + artifact parity ---
  # (the signature itself is verified by `raco rivet verify-release-assets`
  # in the release workflow; this smoke re-checks the structural shape and
  # that the URL-referenced assets exist beside the feed with matching
  # names)
  Assert-True (Test-Path $UpdateManifest) "signed update manifest missing: $UpdateManifest"
  $feed = Get-Content -LiteralPath $UpdateManifest -Raw | ConvertFrom-Json
  Assert-True ($feed.schema -eq 1) "feed wrapper schema: $($feed.schema)"
  Assert-True ($feed.signature.algorithm -eq 'ed25519') "feed signature algorithm: $($feed.signature.algorithm)"
  Assert-True (![string]::IsNullOrEmpty($feed.signature.keyId)) "feed signature keyId missing"
  Assert-True (![string]::IsNullOrEmpty($feed.payload)) "feed payload missing"
  $inner = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($feed.payload)) | ConvertFrom-Json
  Assert-True ($inner.version -eq $Version) "feed inner version '$($inner.version)' does not match release $Version"
  Assert-True ($inner.artifacts.Count -ge 2) "feed must carry at least the zip + msi artifacts, found: $($inner.artifacts.Count)"
  $feedDir = (Resolve-Path (Join-Path $UpdateManifest '..')).Path
  foreach ($a in $inner.artifacts) {
    $name = ($a.url -split '/')[-1]
    Assert-True (Test-Path (Join-Path $feedDir $name)) "feed artifact missing from release set: $name"
    Assert-True ($a.sha256 -match '^[0-9a-f]{64}$') "artifact $name has a malformed sha256"
    $actualHash = (Get-FileHash -LiteralPath (Join-Path $feedDir $name) -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-True ($actualHash -eq $a.sha256) "artifact $name sha256 mismatch against the signed feed"
  }
  Write-Output "smoke: signed update feed (v$($inner.version), $($inner.artifacts.Count) artifacts) OK"

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
