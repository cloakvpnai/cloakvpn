# Builds the Lattice VPN installer from the staged release layout.
# Run build-release.ps1 first. Output: packaging\out\LatticeVPN-<version>-<arch>.msi
#
# Uses WiX Toolset 5.0.2, installed privately under C:\dev\build\wix5. WiX 6 and
# later need their Open Source Maintenance Fee agreement accepted first; moving
# to them is a business decision, and nothing in LatticeVPN.wxs depends on it.
#
# The installer is not code signed here. Sign the three Lattice programs and the
# MSI with the company certificate before it goes to customers (see sign.ps1).
param([ValidateSet('x64','arm64')][string]$Arch = 'x64', [string]$Version = '2.0.0')
$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Wix  = 'C:\dev\build\wix5'
$exe  = Join-Path $Wix 'wix.exe'
if (-not (Test-Path $exe)) {
    & dotnet tool install wix --version 5.0.2 --tool-path $Wix | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'could not install WiX 5.0.2' }
}
$env:WIX_EXTENSIONS = Join-Path $Wix 'ext'
& $exe extension add -g WixToolset.Util.wixext/5.0.2 2>&1 | Out-Null
$stage = Join-Path $Here "out\stage-$Arch"
if (-not (Test-Path (Join-Path $stage 'LatticeService.exe'))) { throw 'run build-release.ps1 first' }
$msi = Join-Path $Here "out\LatticeVPN-$Version-$Arch.msi"
Push-Location $Here
try {
    & $exe build LatticeVPN.wxs -arch $Arch -d "Version=$Version" -d "Stage=$stage" -ext WixToolset.Util.wixext -o $msi
    if ($LASTEXITCODE -ne 0) { throw 'installer build failed' }
} finally { Pop-Location }
$h = (Get-FileHash -Algorithm SHA256 $msi).Hash.ToLowerInvariant()
Write-Output ("built {0} ({1:N1} MB) sha256 {2}" -f $msi, ((Get-Item $msi).Length / 1MB), $h)
