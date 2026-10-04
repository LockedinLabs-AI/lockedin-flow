# Install/remove only this candidate on an ephemeral GitHub Windows runner.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_OS -ne 'Windows' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'This destructive installation test is restricted to an ephemeral Windows CI runner.'
}
Set-Location (Split-Path -Parent $PSScriptRoot)

function Assert-Payload([string] $Directory) {
    $binary = Join-Path $Directory 'lockedin-flow-desktop.exe'
    if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) { throw 'Installed application is missing.' }
    if ((Get-Item -LiteralPath $binary).VersionInfo.ProductName -ne 'LockedIn Flow') {
        throw 'Installed executable branding is incorrect.'
    }
    $expectedModel = Get-Content -LiteralPath 'models.json' -Raw | ConvertFrom-Json
    $models = @(Get-ChildItem -LiteralPath $Directory -Recurse -Filter $expectedModel.file)
    if ($models.Count -ne 1) { throw 'Installed offline model is missing or ambiguous.' }
    if ((Get-FileHash -LiteralPath $models[0].FullName -Algorithm SHA256).Hash.ToLower() -ne $expectedModel.sha256) {
        throw 'Installed model digest differs.'
    }
    foreach ($name in @('SBOM.cdx.json', 'THIRD-PARTY-NOTICES.txt', 'LICENSE.txt', 'MODEL.json')) {
        $files = @(Get-ChildItem -LiteralPath $Directory -Recurse -Filter $name)
        if ($files.Count -ne 1) { throw 'An installed compliance resource is missing or ambiguous.' }
        $expected = Get-FileHash -LiteralPath (Join-Path 'app/resources/compliance' $name) -Algorithm SHA256
        if ((Get-FileHash -LiteralPath $files[0].FullName -Algorithm SHA256).Hash -ne $expected.Hash) {
            throw 'Installed compliance resource differs from the reviewed build.'
        }
    }
}

function Assert-Removed([string] $Directory) {
    # NSIS may hand removal to a temporary child. Check actual payload removal.
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $binaryRemains = Test-Path -LiteralPath (Join-Path $Directory 'lockedin-flow-desktop.exe')
        $modelRemains = Test-Path -LiteralPath (Join-Path $Directory 'models/ggml-base.en.bin')
        if (-not $binaryRemains -and -not $modelRemains) { return }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'The uninstaller left application or model payload behind.'
}

$nsis = @(Get-ChildItem -LiteralPath 'target/release/bundle/nsis' -Filter '*-setup.exe')
$msi = @(Get-ChildItem -LiteralPath 'target/release/bundle/msi' -Filter '*.msi')
if ($nsis.Count -ne 1 -or $msi.Count -ne 1) { throw 'Expected exactly one installer of each Windows format.' }
$nsisDirectory = Join-Path $env:LOCALAPPDATA 'LockedIn Flow CI NSIS'
$msiDirectory = Join-Path $env:ProgramFiles 'LockedIn Flow CI MSI'
foreach ($directory in @($nsisDirectory, $msiDirectory)) {
    if (Test-Path -LiteralPath $directory) { throw 'Refusing to replace a pre-existing installation test target.' }
}

$installed = Start-Process -FilePath $nsis[0].FullName -ArgumentList "/S /D=$nsisDirectory" -Wait -PassThru
if ($installed.ExitCode -ne 0) { throw 'NSIS installation failed.' }
try { Assert-Payload $nsisDirectory } finally {
    $uninstaller = Join-Path $nsisDirectory 'uninstall.exe'
    if (-not (Test-Path -LiteralPath $uninstaller -PathType Leaf)) { throw 'NSIS uninstaller is missing.' }
    $removed = Start-Process -FilePath $uninstaller -ArgumentList '/S' -Wait -PassThru
    if ($removed.ExitCode -ne 0) { throw 'NSIS removal failed.' }
    Assert-Removed $nsisDirectory
}
Write-Output 'NSIS installation, branding, resource integrity, and removal passed.'

# Standard Windows Installer options. No auto-launch or forced restart.
# Keep the NSIS directory preference intact: MSI must honor the explicit
# administrator destination even after another installer format was removed.
$msiPath = $msi[0].FullName
$installed = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$msiPath`" /qn /norestart INSTALLDIR=`"$msiDirectory`"" -Wait -PassThru
if ($installed.ExitCode -ne 0) { throw 'MSI installation did not complete without a restart.' }
try {
    Assert-Payload $msiDirectory
    Assert-Removed $nsisDirectory
} finally {
    $removed = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/x `"$msiPath`" /qn /norestart" -Wait -PassThru
    if ($removed.ExitCode -ne 0) { throw 'MSI removal did not complete without a restart.' }
    Assert-Removed $msiDirectory
}
Write-Output 'MSI installation, branding, resource integrity, and removal passed.'
git diff --exit-code -- Cargo.lock package-lock.json
if ($LASTEXITCODE -ne 0) { throw 'Installation changed a lockfile.' }
