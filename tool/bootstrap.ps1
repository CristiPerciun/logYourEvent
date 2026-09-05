# Prepares every package for development on Windows.
#   pwsh tool/bootstrap.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

foreach ($pkg in 'lye_core', 'lye_io', 'lye_server', 'lye_realm') {
  Write-Host "== $pkg" -ForegroundColor Cyan
  Push-Location "$root/packages/$pkg"
  dart pub get
  Pop-Location
}

Write-Host '== lye_realm: native binaries and generated models' -ForegroundColor Cyan
Push-Location "$root/packages/lye_realm"
dart run realm_dart install
dart run realm_dart generate
Pop-Location

Write-Host '== lye_flutter' -ForegroundColor Cyan
Push-Location "$root/packages/lye_flutter"
flutter pub get
Pop-Location

Write-Host 'bootstrap done' -ForegroundColor Green
