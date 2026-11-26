# Builds the release layout of Lattice VPN for Windows into packaging\out\stage:
# the service, the app, the two native libraries and the license texts, with the
# .NET runtime included so customers need to install nothing else.
# Usage: build-release.ps1 [-Arch x64|arm64]
param([ValidateSet('x64','arm64')][string]$Arch = 'x64')
$ErrorActionPreference = 'Stop'
$Here  = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root  = Split-Path -Parent $Here
$Repo  = (Resolve-Path (Join-Path $Root '..\..')).Path
$Stage = Join-Path $Here "out\stage-$Arch"
$Native = Join-Path $Root "native\out\$Arch"

foreach ($f in 'lattice_tls.dll','wintun.dll') { if (-not (Test-Path (Join-Path $Native $f))) { throw "$f for $Arch is missing; run the scripts in native\ first" } }
if (Test-Path $Stage) { Remove-Item -Recurse -Force $Stage }

foreach ($project in 'Lattice.Service','Lattice.App') {
    & dotnet publish (Join-Path $Root "src\$project\$project.csproj") -c Release -r "win-$Arch" --self-contained true `
        -p:PublishReadyToRun=true -p:DebugType=none -p:DebugSymbols=false -o $Stage -nologo -v q
    if ($LASTEXITCODE -ne 0) { throw "publish of $project failed" }
}
Copy-Item (Join-Path $Native 'lattice_tls.dll'), (Join-Path $Native 'wintun.dll') $Stage -Force

$lic = Join-Path $Stage 'Licenses'
New-Item -ItemType Directory -Force -Path $lic | Out-Null
Copy-Item (Join-Path $Root 'native\out\wintun-LICENSE.txt') (Join-Path $lic 'Wintun-LICENSE.txt') -Force
$openssl = Get-ChildItem 'C:\dev\build' -Directory -Filter 'openssl-win-*-src' | Select-Object -First 1
if ($openssl) { Copy-Item (Join-Path $openssl.FullName 'LICENSE.txt') (Join-Path $lic 'OpenSSL-LICENSE.txt') -Force }
Copy-Item (Join-Path $Here 'ThirdPartyNotices.txt') $lic -Force
Copy-Item (Join-Path $Here 'flag-icons-LICENSE.txt') $lic -Force

$size = (Get-ChildItem $Stage -Recurse -File | Measure-Object Length -Sum).Sum
Write-Output ("staged {0} files, {1:N0} MB in {2}" -f (Get-ChildItem $Stage -Recurse -File).Count, ($size / 1MB), $Stage)
