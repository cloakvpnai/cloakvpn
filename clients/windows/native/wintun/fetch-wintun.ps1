# Fetches the official signed Wintun build (the TUN adapter driver, by WireGuard
# LLC) and places wintun.dll beside lattice_tls.dll:
#   native\out\x64\wintun.dll
#   native\out\arm64\wintun.dll
#
# Wintun is used only through its published wintun.h interface and is shipped
# unmodified, which is what its prebuilt binaries license allows for a closed
# source application. The license text is copied to native\out\ for the
# installer's notices. Source: https://www.wintun.net/
#
# The archive is checked against the SHA-256 published on wintun.net, and each
# DLL must carry a valid Authenticode signature from WireGuard LLC.
param([string]$Work = 'C:\dev\build')
$ErrorActionPreference = 'Stop'

$V   = '0.14.1'
$SHA = '07c256185d6ee3652e09fa55c0b673e2624b565e02c4b9091c79ca7d2f24ef51'
$Signer = 'WireGuard LLC'

$Here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$Native = Split-Path -Parent $Here
$zip    = Join-Path $Work "wintun-$V.zip"
$dir    = Join-Path $Work "wintun-$V"

New-Item -ItemType Directory -Force -Path $Work | Out-Null
if (-not (Test-Path $zip)) {
    Write-Output "downloading wintun-$V.zip"
    & curl.exe -fsSL -o $zip "https://www.wintun.net/builds/wintun-$V.zip"
    if ($LASTEXITCODE -ne 0) { throw 'download failed' }
}
$actual = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLowerInvariant()
if ($actual -ne $SHA) { throw "checksum mismatch: expected $SHA, got $actual" }
Write-Output "wintun-$V.zip: checksum OK"

if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
Expand-Archive -Path $zip -DestinationPath $dir

foreach ($pair in @(@('amd64','x64'), @('arm64','arm64'))) {
    $src = Join-Path $dir ("wintun\bin\{0}\wintun.dll" -f $pair[0])
    if (-not (Test-Path $src)) { throw "missing $src" }
    $sig = Get-AuthenticodeSignature $src
    if ($sig.Status -ne 'Valid') { throw "$src signature is $($sig.Status)" }
    if ($sig.SignerCertificate.Subject -notmatch [regex]::Escape($Signer)) { throw "$src is signed by $($sig.SignerCertificate.Subject)" }
    $out = Join-Path $Native ("out\{0}" -f $pair[1])
    New-Item -ItemType Directory -Force -Path $out | Out-Null
    Copy-Item $src (Join-Path $out 'wintun.dll') -Force
    $h = (Get-FileHash -Algorithm SHA256 $src).Hash.ToLowerInvariant()
    Write-Output ("{0,-6} wintun.dll  signed by {1}  sha256 {2}" -f $pair[1], $Signer, $h)
}
$license = Get-ChildItem -Path (Join-Path $dir 'wintun') -Filter '*LICENSE*' -File | Select-Object -First 1
if ($license) { Copy-Item $license.FullName (Join-Path $Native 'out\wintun-LICENSE.txt') -Force; Write-Output "license: $($license.Name)" }
Write-Output 'WINTUN READY'
