# Read-only probe. Never run the prerequisite executable or change trust policy.
param([Parameter(Mandatory = $true)][string] $InputFile)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $item = Get-Item -LiteralPath $InputFile
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Expected a regular installer file.'
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $item.FullName
    if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or $null -eq $signature.TimeStamperCertificate) {
        throw 'Expected a valid timestamped signature.'
    }
    if ($signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)O=Microsoft Corporation(?:,|$)') {
        throw 'Unexpected publisher.'
    }
    $version = $item.VersionInfo
    $record = [ordered]@{
        bytes = $item.Length
        sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        fileVersion = "$($version.FileMajorPart).$($version.FileMinorPart).$($version.FileBuildPart).$($version.FilePrivatePart)"
        publisher = 'Microsoft Corporation'
        signatureStatus = 'Valid'
        signerThumbprint = $signature.SignerCertificate.Thumbprint
        timestampThumbprint = $signature.TimeStamperCertificate.Thumbprint
    }
    $record | ConvertTo-Json -Compress
} catch {
    # Native errors and certificate subjects can disclose host information.
    [Console]::Error.WriteLine('Windows prerequisite signature inspection failed; details withheld.')
    exit 1
}
