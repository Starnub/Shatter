# SHATTER M1 checks in one go (Docs/HANDOFF.md): debug-layer run, screenshot, benchmark sweep.
#   powershell -ExecutionPolicy Bypass -File Tools\m1_checks.ps1 [-Quick] [-SkipSweep]
# Everything lands in Tools\out\ (gitignored):
#   m1_debug_output.log     all OutputDebugString text (Donut log, D3D12 debug layer, NVRHI validation), via DebugView
#   m1_debug_problems.txt   just the errors / warnings from it
#   points.png (+ .exr)     4K screenshot; points_preview.jpg is a 1600 px copy
#   points\summary.json     benchmark sweep table
param([switch]$Quick, [switch]$SkipSweep, [int]$TimeoutSeconds = 300)
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $root 'Tools\out'
$exe = Join-Path $root 'bin\Rtxpt.exe'
New-Item -ItemType Directory -Force -Path $out | Out-Null
if (-not (Test-Path $exe)) { throw "Not built: $exe" }

function Run-App([string]$name, [string]$appArgs) {
    Write-Host "== $name : $appArgs"
    $p = Start-Process -FilePath $exe -ArgumentList $appArgs -WorkingDirectory (Split-Path $exe) -PassThru
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
        Stop-Process -Id $p.Id -Force
        Write-Warning "$name : TIMEOUT after $TimeoutSeconds s (killed)"
        return 'timeout'
    }
    Write-Host "   exit code $($p.ExitCode)"
    return $p.ExitCode
}

# DebugView captures OutputDebugString from GUI apps (Donut logs there, not to stdout)
$dbgview = Join-Path $out 'Dbgview64.exe'
if (-not (Test-Path $dbgview)) { Invoke-WebRequest 'https://live.sysinternals.com/Dbgview64.exe' -OutFile $dbgview }
$debugLog = Join-Path $out 'm1_debug_output.log'
Remove-Item $debugLog -ErrorAction SilentlyContinue
Start-Process -FilePath $dbgview -ArgumentList '/accepteula', '/t', '/f', '/l', "`"$debugLog`""
Start-Sleep -Seconds 2

$results = [ordered]@{}
$results.debug_run = Run-App 'debug layer + NVRHI validation, 100M points' "--scene kitchen.scene.json --camera default --debug --nonInteractive --fg 0 --bench 5 --pointsM 100 --benchOut `"$out\m1_debug_bench.json`""
$results.screenshot = Run-App 'screenshot, 1B points' "--scene kitchen.scene.json --width 3840 --height 2160 --camera default --nonInteractive --fg 0 --screenshot `"$out\points.png`" --frame 64"

Start-Process -FilePath $dbgview -ArgumentList '/q' -Wait
Start-Sleep -Seconds 1
if (Test-Path $debugLog) {
    Select-String -Path $debugLog -Pattern 'ERROR|WARNING|CORRUPTION|D3D12 ERROR|D3D12 WARNING|Point|Shatter|failed' |
        ForEach-Object { $_.Line } | Set-Content (Join-Path $out 'm1_debug_problems.txt')
}

$png = Join-Path $out 'points.png'
if (Test-Path $png) {
    Add-Type -AssemblyName System.Drawing
    $img = [System.Drawing.Image]::FromFile($png)
    $w = 1600; $h = [int]($img.Height * $w / $img.Width)
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.DrawImage($img, 0, 0, $w, $h)
    $bmp.Save((Join-Path $out 'points_preview.jpg'), [System.Drawing.Imaging.ImageFormat]::Jpeg)
    $g.Dispose(); $bmp.Dispose(); $img.Dispose()
}

if (-not $SkipSweep) {
    $sweepArgs = @('-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'bench_points.ps1'))
    if ($Quick) { $sweepArgs += '-Quick' }
    & powershell @sweepArgs
}

Write-Host "== results"
$results.GetEnumerator() | ForEach-Object { Write-Host "$($_.Key): $($_.Value)" }
$problems = Join-Path $out 'm1_debug_problems.txt'
if (Test-Path $problems) { Write-Host "debug problems: $((Get-Content $problems | Measure-Object).Count) lines in $problems" }
Write-Host "M1 CHECKS DONE"
