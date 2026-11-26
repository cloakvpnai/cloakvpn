# Builds OpenSSL 3.5.9 (Apache 2.0) as static libraries for the Windows app and
# links them under native\Vendor\:
#   Vendor\openssl-win-x64     Windows x64   (VC-WIN64A)
#   Vendor\openssl-win-arm64   Windows arm64 (VC-WIN64-ARM)
#
# Same source archive, checksum and option set as clients/apple-tls/build-openssl.sh.
#
# Needs: Visual Studio Build Tools (MSVC + Windows SDK), Strawberry Perl, NASM.
# Usage: build-openssl.ps1 [-Only win-x64|win-arm64] [-Work C:\dev\build]
#
# Windows hardening. OpenSSL compiles three directory paths into the library
# (OPENSSLDIR, ENGINESDIR, MODULESDIR) and by default reads openssl.cnf from the
# first one at run time. This library ends up inside a service that runs as
# LocalSystem, so those paths must never be somewhere an ordinary user can
# write. They are set to the product's own folder under Program Files, which
# only administrators can write and where the installer never places a config
# file. The build itself is staged elsewhere with DESTDIR. In addition:
#   - no-dso means no provider or engine module can be loaded from disk at all;
#   - no-winstore removes the Windows certificate store loader, because the
#     client trusts only the CA it is handed, never the system store;
#   - lattice_tls_win.c turns automatic config loading off before first use.
param(
    [string]$Only = '',
    [string]$Work = 'C:\dev\build'
)
$ErrorActionPreference = 'Stop'

$V    = '3.5.9'
$SHA  = '603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a'
$Opts = 'no-shared no-tests no-docs no-apps no-engine no-legacy no-ssl3 no-comp no-dso no-srp no-psk no-weak-ssl-ciphers no-async'
$WinOpts = 'no-winstore'

$BakedPrefix = 'C:\Program Files\Lattice VPN\openssl'
$BakedSslDir = 'C:\Program Files\Lattice VPN\ssl'

$Here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$Vendor = Join-Path (Split-Path -Parent $Here) 'Vendor'
$Perl   = 'C:\Strawberry\perl\bin\perl.exe'
$Nasm   = 'C:\Program Files\NASM'

$vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) { throw 'Visual Studio Build Tools not found (vswhere missing)' }
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw 'MSVC x64 tools not installed' }
$vcvarsDir = Join-Path $vs 'VC\Auxiliary\Build'
if (-not (Test-Path $Perl)) { throw "Strawberry Perl not found at $Perl" }
if (-not (Test-Path (Join-Path $Nasm 'nasm.exe'))) { throw "NASM not found in $Nasm" }

New-Item -ItemType Directory -Force -Path $Work, $Vendor, (Join-Path $Work 'logs') | Out-Null
$tarball = Join-Path $Work "openssl-$V.tar.gz"
if (-not (Test-Path $tarball)) {
    Write-Output "downloading openssl-$V.tar.gz"
    & curl.exe -fsSL -o $tarball "https://github.com/openssl/openssl/releases/download/openssl-$V/openssl-$V.tar.gz"
    if ($LASTEXITCODE -ne 0) { throw 'download failed' }
}
$actual = (Get-FileHash -Algorithm SHA256 $tarball).Hash.ToLowerInvariant()
if ($actual -ne $SHA) { throw "checksum mismatch: expected $SHA, got $actual" }
Write-Output "openssl-$V.tar.gz: checksum OK"

function Build([string]$name, [string]$target, [string]$vcvars) {
    if ($Only -and $Only -ne $name) { return }
    $src   = Join-Path $Work "openssl-$name-src"
    $stage = Join-Path $Work "openssl-$name-stage"
    $log   = Join-Path $Work "logs\openssl-$name.log"
    $bat   = Join-Path $Work "build-openssl-$name.cmd"
    foreach ($d in $src, $stage) { if (Test-Path $d) { Remove-Item -Recurse -Force $d } }
    New-Item -ItemType Directory -Force -Path $src | Out-Null
    Write-Output "[$name] extracting"
    & tar.exe -xzf $tarball -C $src --strip-components 1
    if ($LASTEXITCODE -ne 0) { throw "[$name] extract failed" }

    $lines = @(
        '@echo off',
        ('call "{0}" || exit /b 1' -f (Join-Path $vcvarsDir $vcvars)),
        ('set "PATH={0};{1};%PATH%"' -f (Split-Path -Parent $Perl), $Nasm),
        ('cd /d "{0}" || exit /b 1' -f $src),
        ('perl Configure {0} {1} {2} "--prefix={3}" "--openssldir={4}" || exit /b 1' -f $target, $Opts, $WinOpts, $BakedPrefix, $BakedSslDir),
        'nmake /nologo build_libs || exit /b 1',
        ('nmake /nologo install_dev "DESTDIR={0}" || exit /b 1' -f $stage)
    )
    Set-Content -Path $bat -Value $lines -Encoding ASCII
    Write-Output "[$name] configuring and building (log: $log)"
    & cmd.exe /c "$bat > `"$log`" 2>&1"
    if ($LASTEXITCODE -ne 0) { throw "[$name] build failed, see $log" }

    $installed = Join-Path $stage 'Program Files\Lattice VPN\openssl'
    if (-not (Test-Path (Join-Path $installed 'lib\libcrypto.lib'))) { throw "[$name] libcrypto.lib not produced" }
    $link = Join-Path $Vendor "openssl-$name"
    if (Test-Path $link) { cmd.exe /c rmdir "$link" | Out-Null }
    New-Item -ItemType Junction -Path $link -Target $installed | Out-Null
    Write-Output "[$name] done -> $link"
}

Build 'win-x64'   'VC-WIN64A'    'vcvars64.bat'
Build 'win-arm64' 'VC-WIN64-ARM' 'vcvarsamd64_arm64.bat'
Write-Output 'OPENSSL BUILD COMPLETE'
