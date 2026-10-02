# SHATTER: one-call screenshot for iteration. Runs the app, captures frame N, exits.
# Writes Tools\out\shot\<Name>.png (+ .exr) and a small <Name>.jpg preview (read the JPG: cheap to view).
#   powershell -ExecutionPolicy Bypass -File Tools\shot.ps1 -Name test
#   ... -Scene bistro-programmer-art.scene.json -Camera "" -Width 1920 -Height 1080 -Extra "--pointLod 0" -Crop "0,0,640,360"
# -Camera "" skips --camera (named presets exist only where saved: Game/camera_presets.json).
# -Crop "x,y,w,h" also writes <Name>.crop.png at 1:1 for checking fine detail.
param(
    [string]$Name = 'shot',
    [string]$Scene = 'kitchen.scene.json',
    [string]$Camera = 'default',
    [int]$Width = 1280,
    [int]$Height = 720,
    [int]$Frame = 64,
    [int]$PreviewWidth = 960,
    [string]$Crop = '',
    [string]$Extra = ''
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $root 'bin\Rtxpt.exe'
$out = Join-Path $root 'Tools\out\shot'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$png = Join-Path $out "$Name.png"
Remove-Item "$png*", (Join-Path $out "$Name.jpg") -ErrorAction SilentlyContinue

$argList = "--scene $Scene --width $Width --height $Height --nonInteractive --fg 0 --screenshot `"$png`" --frame $Frame $Extra"
if ($Camera) { $argList += " --camera $Camera" }
$p = Start-Process -FilePath $exe -ArgumentList $argList -WorkingDirectory (Split-Path $exe) -PassThru
if (-not $p.WaitForExit(120000)) { Stop-Process -Id $p.Id -Force; throw "TIMEOUT: $argList" }
if (-not (Test-Path $png)) { throw "No screenshot written (exit code $($p.ExitCode)): $argList" }

Add-Type -AssemblyName System.Drawing
$img = [System.Drawing.Bitmap]::FromFile($png)
try {
    if ($Crop) {
        $c = $Crop.Split(',') | ForEach-Object { [int]$_ }
        $part = $img.Clone((New-Object System.Drawing.Rectangle $c[0], $c[1], $c[2], $c[3]), $img.PixelFormat)
        $part.Save((Join-Path $out "$Name.crop.png"), [System.Drawing.Imaging.ImageFormat]::Png)
        $part.Dispose()
    }
    $w = [math]::Min($PreviewWidth, $img.Width)
    $h = [int]($img.Height * $w / $img.Width)
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.DrawImage($img, 0, 0, $w, $h)
    $bmp.Save((Join-Path $out "$Name.jpg"), [System.Drawing.Imaging.ImageFormat]::Jpeg)
    $g.Dispose(); $bmp.Dispose()
}
finally { $img.Dispose() }
"OK $(Join-Path $out "$Name.jpg")"
