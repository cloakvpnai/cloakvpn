# Fetches NASA's public domain Earth imagery and prepares the three textures the
# globe in the app is drawn from:
#   Assets\Earth\day.jpg     4096 x 2048  Blue Marble Next Generation, July, with
#                                         topography and bathymetry (NASA Earth Observatory,
#                                         Reto Stockli)
#   Assets\Earth\night.jpg   4096 x 2048  Earth at Night, Black Marble 2016 (NASA Earth
#                                         Observatory, Joshua Stevens, Suomi NPP VIIRS data
#                                         from Miguel Roman, NASA GSFC)
#   Assets\Earth\clouds.jpg  2048 x 1024  Blue Marble clouds (NASA GSFC, Reto Stockli)
# NASA imagery is not copyrighted; NASA asks for the credit above, which the app's
# About page and the notices file carry.
param([string]$Work = 'C:\dev\build\earth')
$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Out  = (Join-Path (Split-Path -Parent (Split-Path -Parent $Here)) 'src\Lattice.App\Assets\Earth')
New-Item -ItemType Directory -Force -Path $Work, $Out | Out-Null
Add-Type -AssemblyName System.Drawing

$sources = @(
  @{ name = 'day';    w = 4096; h = 2048; q = 90; url = 'https://assets.science.nasa.gov/content/dam/science/esd/eo/images/bmng/bmng-topography-bathymetry/july/world.topo.bathy.200407.3x5400x2700.jpg' },
  @{ name = 'night';  w = 4096; h = 2048; q = 88; url = 'https://assets.science.nasa.gov/content/dam/science/esd/eo/images/imagerecords/144000/144898/BlackMarble_2016_3km.jpg' },
  @{ name = 'clouds'; w = 2048; h = 1024; q = 88; url = 'https://assets.science.nasa.gov/content/dam/science/esd/eo/content-feature/bluemarble/images/cloud_combined_2048.jpg' }
)
$jpeg = [Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
foreach ($s in $sources) {
  $raw = Join-Path $Work ($s.name + '-source.jpg')
  if (-not (Test-Path $raw)) {
    & curl.exe -fsSL -o $raw $s.url
    if ($LASTEXITCODE -ne 0) { throw "download failed: $($s.url)" }
  }
  $src = [Drawing.Image]::FromFile($raw)
  if ([math]::Abs($src.Width / $src.Height - 2) -gt 0.01) { throw "$($s.name): not a 2:1 world map ($($src.Width) x $($src.Height))" }
  $dst = New-Object Drawing.Bitmap $s.w, $s.h, ([Drawing.Imaging.PixelFormat]::Format24bppRgb)
  $g = [Drawing.Graphics]::FromImage($dst)
  $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $attr = New-Object Drawing.Imaging.ImageAttributes
  $attr.SetWrapMode([Drawing.Drawing2D.WrapMode]::TileFlipXY)   # no dark fringe at the map's edges
  $g.DrawImage($src, (New-Object Drawing.Rectangle 0, 0, $s.w, $s.h), 0, 0, $src.Width, $src.Height, [Drawing.GraphicsUnit]::Pixel, $attr)
  $g.Dispose()
  $p = New-Object Drawing.Imaging.EncoderParameters 1
  $p.Param[0] = New-Object Drawing.Imaging.EncoderParameter ([Drawing.Imaging.Encoder]::Quality), ([long]$s.q)
  $file = Join-Path $Out ($s.name + '.jpg')
  $dst.Save($file, $jpeg, $p)
  Write-Output ("{0,-7} source {1} x {2} ({3:N1} MB) -> {4} x {5} ({6:N0} KB)" -f $s.name, $src.Width, $src.Height, ((Get-Item $raw).Length / 1MB), $s.w, $s.h, ((Get-Item $file).Length / 1KB))
  $src.Dispose(); $dst.Dispose()
}
Write-Output 'EARTH TEXTURES READY'
