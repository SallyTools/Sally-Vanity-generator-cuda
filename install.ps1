# Sally-Vanity-generator-cuda — Windows installer wrapper.
# Run:  powershell -ExecutionPolicy Bypass -File install.ps1
$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot
$py = (Get-Command python -ErrorAction SilentlyContinue) ?? (Get-Command py -ErrorAction SilentlyContinue)
if (-not $py) { Write-Error "Python not found. Install Python 3 from https://python.org and re-run." }
& $py.Source install.py @args
