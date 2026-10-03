# SHATTER: pull the current branch and build Release, printing only errors.
#   powershell -ExecutionPolicy Bypass -File Tools\build.ps1 [-Configure]
# -Configure re-runs CMake first: required after adding or removing source files (Game/ globs its sources).
param([switch]$Configure)
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$branch = git rev-parse --abbrev-ref HEAD
git pull -q origin $branch 2>&1 | Out-Host
git log --oneline -1
# Shatter scenes live in Game/Scenes; Assets is NVIDIA's submodule, so install them there.
Copy-Item (Join-Path $root 'Game\Scenes\*.scene.json') (Join-Path $root 'Assets') -Force
if ($Configure) { cmake -S . -B build 2>&1 | Select-String -Pattern 'Error|error' | ForEach-Object { $_.Line } }
$log = cmake --build build --config Release --parallel 2>&1
$code = $LASTEXITCODE
$log | Out-File -Encoding utf8 (Join-Path $root 'Tools\out\build.log')
$log | Select-String -Pattern '\berror\b|fatal error|LNK\d{4}' | Where-Object { $_.Line -notmatch '\b0 Error' } |
    Select-Object -First 30 | ForEach-Object { $_.Line.Trim() }
"BUILD EXIT $code"
