# Builds lattice_tls.dll: the shared C layer from
# clients\apple-tls\Sources\CLatticeTLS (compiled as is) plus lattice_tls_win.c,
# statically linked against the OpenSSL built by ..\openssl\build-openssl.ps1.
# The C runtime is linked statically too, so the DLL needs no redistributable.
#
# Output: native\out\<arch>\lattice_tls.dll
# Usage:  build-native.ps1 [-Arch x64|arm64]
param([ValidateSet('x64','arm64')][string]$Arch = 'x64')
$ErrorActionPreference = 'Stop'

$Here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$Native  = Split-Path -Parent $Here
$Repo    = (Resolve-Path (Join-Path $Native '..\..\..')).Path
$Shared  = Join-Path $Repo 'clients\apple-tls\Sources\CLatticeTLS'
$OpenSSL = Join-Path $Native "Vendor\openssl-win-$Arch"
$Out     = Join-Path $Native "out\$Arch"
$Obj     = Join-Path $Native "obj\$Arch"

if (-not (Test-Path (Join-Path $OpenSSL 'lib\libssl.lib'))) { throw "OpenSSL for $Arch not built. Run ..\openssl\build-openssl.ps1 first." }
$vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw 'MSVC not installed' }
$vcvars = Join-Path $vs ('VC\Auxiliary\Build\' + $(if ($Arch -eq 'arm64') { 'vcvarsamd64_arm64.bat' } else { 'vcvars64.bat' }))

New-Item -ItemType Directory -Force -Path $Out, $Obj | Out-Null

# /MT        static C runtime, matching the OpenSSL static libraries
# /GS /sdl   stack protection and extra security checks
# /guard:cf  control flow guard
$cflags = '/nologo /c /O2 /W3 /MT /GS /sdl /guard:cf /DWIN32_LEAN_AND_MEAN /D_CRT_SECURE_NO_WARNINGS'
$lflags = '/nologo /DLL /DYNAMICBASE /NXCOMPAT /HIGHENTROPYVA /guard:cf /OPT:REF /OPT:ICF /DEBUG:NONE'
$syslibs = 'ws2_32.lib crypt32.lib advapi32.lib user32.lib gdi32.lib bcrypt.lib'

$bat = Join-Path $Obj 'build.cmd'
$lines = @(
    '@echo off',
    ('call "{0}" || exit /b 1' -f $vcvars),
    ('cl {0} /I"{1}\include" /I"{2}\include" /Fo"{3}\\" "{1}\lattice_tls.c" "{4}\lattice_tls_win.c" || exit /b 1' -f $cflags, $Shared, $OpenSSL, $Obj, $Here),
    ('link {0} /DEF:"{1}\lattice_tls.def" /OUT:"{2}\lattice_tls.dll" /IMPLIB:"{3}\lattice_tls.lib" "{3}\lattice_tls.obj" "{3}\lattice_tls_win.obj" "{4}\lib\libssl.lib" "{4}\lib\libcrypto.lib" {5} || exit /b 1' -f $lflags, $Here, $Out, $Obj, $OpenSSL, $syslibs)
)
Set-Content -Path $bat -Value $lines -Encoding ASCII
& cmd.exe /c $bat
if ($LASTEXITCODE -ne 0) { throw 'lattice_tls.dll build failed' }

$dll = Join-Path $Out 'lattice_tls.dll'
$hash = (Get-FileHash -Algorithm SHA256 $dll).Hash.ToLowerInvariant()
Write-Output ("built {0} ({1:N0} bytes) sha256 {2}" -f $dll, (Get-Item $dll).Length, $hash)
