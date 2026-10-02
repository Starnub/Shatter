# SHATTER M1: point raster throughput sweep (PLAN 11, M1 "done when").
# Run from anywhere after a Release build:
#   powershell -ExecutionPolicy Bypass -File Tools\bench_points.ps1            # full sweep, 10 s per run
#   powershell -ExecutionPolicy Bypass -File Tools\bench_points.ps1 -Quick     # 3 runs
# Writes Tools\out\points\<run>.json per run and Tools\out\points\summary.json, and prints a table.
param(
    [int]$Seconds = 10,
    [switch]$Quick,
    [string]$Scene = 'kitchen.scene.json',
    [string]$Camera = 'default'
)
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $root 'bin\Rtxpt.exe'
if (-not (Test-Path $exe)) { throw "Not built: $exe" }
$outDir = Join-Path $root 'Tools\out\points'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

# raw_* runs disable LOD, so every point in the frustum is rasterized: that is the throughput curve.
$runs = @(
    @{ tag = 'raw_0250M_int64';          args = '--pointsM 250  --pointLod 0 --pointAtomic 0 --pointAgg 1' },
    @{ tag = 'raw_0500M_int64';          args = '--pointsM 500  --pointLod 0 --pointAtomic 0 --pointAgg 1' },
    @{ tag = 'raw_1000M_int64';          args = '--pointsM 1000 --pointLod 0 --pointAtomic 0 --pointAgg 1' },
    @{ tag = 'raw_2000M_int64';          args = '--pointsM 2000 --pointLod 0 --pointAtomic 0 --pointAgg 1' },
    @{ tag = 'raw_1000M_int64_noagg';    args = '--pointsM 1000 --pointLod 0 --pointAtomic 0 --pointAgg 0' },
    @{ tag = 'raw_1000M_fp16x4';         args = '--pointsM 1000 --pointLod 0 --pointAtomic 1 --pointAgg 1' },
    @{ tag = 'raw_1000M_fp16x4_noagg';   args = '--pointsM 1000 --pointLod 0 --pointAtomic 1 --pointAgg 0' },
    @{ tag = 'lod16_1000M_int64';        args = '--pointsM 1000 --pointLod 1 --pointPpp 16 --pointAtomic 0 --pointAgg 1' },
    @{ tag = 'lod16_4000M_int64';        args = '--pointsM 4000 --pointLod 1 --pointPpp 16 --pointAtomic 0 --pointAgg 1' }
)
if ($Quick) { $runs = $runs | Where-Object { $_.tag -in @('raw_1000M_int64', 'raw_1000M_fp16x4', 'lod16_1000M_int64') } }

foreach ($r in $runs) {
    $json = Join-Path $outDir "$($r.tag).json"
    Remove-Item $json -ErrorAction SilentlyContinue
    $argList = "--scene $Scene --width 3840 --height 2160 --camera $Camera --fg 0 --bench $Seconds --benchOut `"$json`" $($r.args)"
    Write-Host "== $($r.tag): $argList"
    $p = Start-Process -FilePath $exe -ArgumentList $argList -WorkingDirectory (Split-Path $exe) -Wait -PassThru
    if ($p.ExitCode -ne 0) { Write-Warning "$($r.tag): exit code $($p.ExitCode)" }
    if (-not (Test-Path $json)) { Write-Warning "$($r.tag): no bench JSON written" }
}

$rows = foreach ($r in $runs) {
    $f = Join-Path $outDir "$($r.tag).json"
    if (-not (Test-Path $f)) { continue }
    $j = Get-Content $f -Raw | ConvertFrom-Json
    $raster = [double]$j.gpu_passes.Points_Raster.avg_ms
    $rendered = [double]$j.points.rendered_points_avg
    [pscustomobject]@{
        run          = $r.tag
        total_M      = [math]::Round([double]$j.points.total_points / 1e6, 0)
        rendered_M   = [math]::Round($rendered / 1e6, 1)
        cull_ms      = [math]::Round([double]$j.gpu_passes.Points_Cull.avg_ms, 3)
        raster_ms    = [math]::Round($raster, 3)
        composite_ms = [math]::Round([double]$j.gpu_passes.Points_Composite.avg_ms, 3)
        Gpts_per_s   = if ($raster -gt 0) { [math]::Round($rendered / ($raster * 1e-3) / 1e9, 2) } else { $null }
        path_ms      = [math]::Round([double]$j.gpu_passes.PathTrace.avg_ms, 2)
        frame_ms     = [math]::Round([double]$j.frames.avg_ms, 2)
        gen_gpu_ms   = [math]::Round([double]$j.points.generate_gpu_ms, 1)
        gen_cpu_ms   = [math]::Round([double]$j.points.generate_cpu_ms, 0)
        points_GB    = [math]::Round([double]$j.points.gpu_mb / 1024, 2)
    }
}
$rows | Format-Table -AutoSize
$rows | ConvertTo-Json | Set-Content (Join-Path $outDir 'summary.json')
Write-Host "Summary: $(Join-Path $outDir 'summary.json')"
