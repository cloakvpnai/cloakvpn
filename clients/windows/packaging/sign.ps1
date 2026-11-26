# Code signs a Lattice VPN release with the company certificate.
#
# Order for a release:
#   build-release.ps1 -Arch x64
#   sign.ps1 -Arch x64 -Thumbprint <cert thumbprint> -What programs
#   build-msi.ps1 -Arch x64
#   sign.ps1 -Arch x64 -Thumbprint <cert thumbprint> -What installer
#
# The programs are signed before the installer is built so that the copies inside
# the installer carry signatures too. Only Lattice's own files are signed here:
# wintun.dll is already signed by WireGuard LLC and must stay untouched (its
# license covers the unmodified binary), and the .NET files are signed by Microsoft.
#
# The certificate is named by thumbprint and must be in the Windows certificate
# store, which is how hardware tokens and cloud signing services present it. No
# private key file or password is read by this script.
#
# SHA-384 digests are used for the file and for the timestamp, in line with the
# CNSA 2.0 hash requirement the rest of the product follows.
param(
    [ValidateSet('x64','arm64')][string]$Arch = 'x64',
    [Parameter(Mandatory = $true)][string]$Thumbprint,
    [Parameter(Mandatory = $true)][ValidateSet('programs','installer')][string]$What,
    [string]$Version = '2.0.0',
    [string]$TimestampUrl = 'http://timestamp.digicert.com'
)
$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path

$kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
$signtool = Get-ChildItem $kits -Directory -Filter '10.*' | Sort-Object Name -Descending |
    ForEach-Object { Join-Path $_.FullName 'x64\signtool.exe' } | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $signtool) { throw 'signtool.exe not found; install the Windows SDK' }

$Thumbprint = ($Thumbprint -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
$cert = Get-ChildItem Cert:\CurrentUser\My, Cert:\LocalMachine\My -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $Thumbprint } | Select-Object -First 1
if (-not $cert) { throw "no certificate with thumbprint $Thumbprint in the certificate store" }
if ($cert.NotAfter -lt (Get-Date)) { throw "that certificate expired on $($cert.NotAfter)" }
if (-not ($cert.EnhancedKeyUsageList | Where-Object { $_.ObjectId -eq '1.3.6.1.5.5.7.3.3' })) { throw 'that certificate is not a code signing certificate' }
Write-Output "signing as: $($cert.Subject)"

if ($What -eq 'programs') {
    $stage = Join-Path $Here "out\stage-$Arch"
    $files = 'LatticeVPN.exe', 'LatticeVPN.dll', 'LatticeService.exe', 'LatticeService.dll', 'Lattice.Tunnel.dll', 'lattice_tls.dll' |
        ForEach-Object { Join-Path $stage $_ } | Where-Object { Test-Path $_ }
    if (@($files).Count -lt 4) { throw "release layout not found in $stage; run build-release.ps1 first" }
} else {
    $files = @(Join-Path $Here "out\LatticeVPN-$Version-$Arch.msi")
    if (-not (Test-Path $files[0])) { throw 'installer not found; run build-msi.ps1 first' }
}

foreach ($f in $files) {
    & $signtool sign /sha1 $Thumbprint /fd SHA384 /tr $TimestampUrl /td SHA384 /d 'Lattice VPN' /du 'https://latticevpn.ai' $f
    if ($LASTEXITCODE -ne 0) { throw "signing failed: $f" }
    & $signtool verify /pa /tw $f | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "signature did not verify: $f" }
    Write-Output ("signed {0}  sha256 {1}" -f (Split-Path -Leaf $f), (Get-FileHash -Algorithm SHA256 $f).Hash.ToLowerInvariant())
}
Write-Output 'SIGNING COMPLETE'
