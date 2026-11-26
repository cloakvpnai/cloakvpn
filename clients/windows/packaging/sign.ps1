# Code signs a Lattice VPN release as KryptoKnightz LLC.
#
# Order for a release:
#   build-release.ps1 -Arch x64
#   sign.ps1 -Arch x64 -What programs
#   build-msi.ps1 -Arch x64
#   sign.ps1 -Arch x64 -What installer
#
# The programs are signed before the installer is built so that the copies inside
# the installer carry signatures too. Only Lattice's own files are signed here:
# wintun.dll is already signed by WireGuard LLC and must stay untouched (its
# license covers the unmodified binary), and the .NET files are signed by Microsoft.
#
# Two ways to sign:
#
#   -Method artifact (default)
#     Microsoft Azure Artifact Signing. The key lives in Microsoft's service; this
#     script holds no key, no certificate file and no password. It needs:
#       - the Artifact Signing client tools on this PC, installed once with
#           winget install -e --id Microsoft.Azure.ArtifactSigningClientTools
#       - the .NET 8 runtime (those tools use it)
#       - an Azure sign-in on this PC that has the role
#         "Artifact Signing Certificate Profile Signer" on the signing account.
#         Sign in first with:  az login --tenant demetrislatticevpn.onmicrosoft.com
#       - the certificate profile name, which exists only after Microsoft has
#         completed the identity validation.
#     Certificates from this service last three days, so the timestamp is what
#     keeps a signature valid afterwards. A file that fails to timestamp is
#     treated as not signed.
#
#   -Method certificate
#     A certificate from a certificate authority, named by thumbprint and held in
#     the Windows certificate store (which is how hardware tokens and cloud
#     signing services present it).
#
# Digests: Microsoft documents SHA-256 for Artifact Signing, so that is the default
# there. Pass -Digest SHA384 to match the CNSA 2.0 hash used elsewhere in the
# product once it has been confirmed that the service accepts it.
param(
    [ValidateSet('x64','arm64')][string]$Arch = 'x64',
    [Parameter(Mandatory = $true)][ValidateSet('programs','installer')][string]$What,
    [ValidateSet('artifact','certificate')][string]$Method = 'artifact',
    [string]$Version = '2.0.0',

    # Artifact Signing
    [string]$Endpoint = 'https://wus2.codesigning.azure.net',
    [string]$Account = 'kryptoknightz',
    [string]$Profile = '',
    [string]$Dlib = '',

    # Certificate from a certificate authority
    [string]$Thumbprint = '',
    [string]$TimestampUrl = '',

    [ValidateSet('', 'SHA256','SHA384')][string]$Digest = ''
)
$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path

$kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
$signtool = Get-ChildItem $kits -Directory -Filter '10.*' | Sort-Object Name -Descending |
    ForEach-Object { Join-Path $_.FullName 'x64\signtool.exe' } | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $signtool) { throw 'signtool.exe not found; install the Windows SDK' }

if ($What -eq 'programs') {
    $stage = Join-Path $Here "out\stage-$Arch"
    $files = 'LatticeVPN.exe', 'LatticeVPN.dll', 'LatticeService.exe', 'LatticeService.dll', 'Lattice.Tunnel.dll', 'lattice_tls.dll' |
        ForEach-Object { Join-Path $stage $_ } | Where-Object { Test-Path $_ }
    if (@($files).Count -lt 6) { throw "release layout is incomplete in $stage; run build-release.ps1 first" }
} else {
    $files = @(Join-Path $Here "out\LatticeVPN-$Version-$Arch.msi")
    if (-not (Test-Path $files[0])) { throw 'installer not found; run build-msi.ps1 first' }
}

if ($Method -eq 'artifact') {
    if (-not $Profile) { throw 'give -Profile <certificate profile name>. It exists once Microsoft has completed the identity validation.' }
    if (-not $Digest) { $Digest = 'SHA256' }
    if (-not $TimestampUrl) { $TimestampUrl = 'http://timestamp.acs.microsoft.com' }
    if (-not $Dlib) {
        $roots = @($env:LOCALAPPDATA, $env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ }
        $Dlib = $roots | ForEach-Object { Get-ChildItem $_ -Recurse -Filter 'Azure.CodeSigning.Dlib.dll' -ErrorAction SilentlyContinue } |
            Where-Object { $_.FullName -match '\\x64\\' } | Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $Dlib -or -not (Test-Path $Dlib)) {
        throw 'Artifact Signing client tools not found. Install once with: winget install -e --id Microsoft.Azure.ArtifactSigningClientTools'
    }
    # Holds names only. Nothing in this file is secret.
    $metadata = Join-Path $env:TEMP 'lattice-signing-metadata.json'
    @{ Endpoint = $Endpoint; CodeSigningAccountName = $Account; CertificateProfileName = $Profile } | ConvertTo-Json | Set-Content -Path $metadata -Encoding ASCII
    $signArgs = @('sign', '/fd', $Digest, '/tr', $TimestampUrl, '/td', $Digest, '/dlib', $Dlib, '/dmdf', $metadata)
    Write-Output "signing through Azure Artifact Signing: account $Account, profile $Profile"
} else {
    if (-not $Thumbprint) { throw 'give -Thumbprint <certificate thumbprint>' }
    if (-not $Digest) { $Digest = 'SHA384' }
    if (-not $TimestampUrl) { $TimestampUrl = 'http://timestamp.digicert.com' }
    $Thumbprint = ($Thumbprint -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
    $cert = Get-ChildItem Cert:\CurrentUser\My, Cert:\LocalMachine\My -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $Thumbprint } | Select-Object -First 1
    if (-not $cert) { throw "no certificate with thumbprint $Thumbprint in the certificate store" }
    if ($cert.NotAfter -lt (Get-Date)) { throw "that certificate expired on $($cert.NotAfter)" }
    if (-not ($cert.EnhancedKeyUsageList | Where-Object { $_.ObjectId -eq '1.3.6.1.5.5.7.3.3' })) { throw 'that certificate is not a code signing certificate' }
    $signArgs = @('sign', '/sha1', $Thumbprint, '/fd', $Digest, '/tr', $TimestampUrl, '/td', $Digest)
    Write-Output "signing as: $($cert.Subject)"
}

foreach ($f in $files) {
    & $signtool @signArgs /d 'Lattice VPN' /du 'https://latticevpn.ai' $f
    if ($LASTEXITCODE -ne 0) { throw "signing failed: $f" }
    # /pa checks against the same rules Windows uses for downloads; /tw fails a file with no timestamp.
    & $signtool verify /pa /tw $f | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "signature or timestamp did not verify: $f" }
    $who = (Get-AuthenticodeSignature $f).SignerCertificate.Subject
    Write-Output ("signed {0}  by {1}  sha256 {2}" -f (Split-Path -Leaf $f), $who, (Get-FileHash -Algorithm SHA256 $f).Hash.ToLowerInvariant())
}
Write-Output 'SIGNING COMPLETE'
