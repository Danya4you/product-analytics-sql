# =============================================================================
# Прогон аналитических запросов под Windows.
#
#   .\scripts\run_analysis.ps1
#   .\scripts\run_analysis.ps1 -Out report\output.txt
#   .\scripts\run_analysis.ps1 -Only 05
# =============================================================================
param(
    [string] $Out      = '',
    [string] $Only     = '',
    [string] $Database = $(if ($env:PGDATABASE) { $env:PGDATABASE } else { 'timeline_analytics' }),
    [string] $PsqlPath = 'psql'
)

$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')
$env:PGCLIENTENCODING = 'UTF8'

if ($PsqlPath -eq 'psql' -and -not (Get-Command psql -ErrorAction SilentlyContinue)) {
    $found = Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin\psql.exe' -ErrorAction SilentlyContinue |
             Sort-Object FullName -Descending | Select-Object -First 1
    if ($found) { $PsqlPath = $found.FullName } else { throw 'psql не найден. Укажите -PsqlPath.' }
}

$files = Get-ChildItem sql/analysis/*.sql | Sort-Object Name
if ($Only) { $files = $files | Where-Object { $_.Name.StartsWith($Only) } }

$lines = foreach ($f in $files) {
    ''
    '########################################################################'
    "# $($f.Name)"
    '########################################################################'
    & $PsqlPath -d $Database --quiet --no-psqlrc -v ON_ERROR_STOP=1 -f "sql/analysis/$($f.Name)"
    if ($LASTEXITCODE -ne 0) { throw "Запрос $($f.Name) завершился с ошибкой" }
}

if ($Out) {
    $dir = Split-Path $Out -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $lines | Out-File -FilePath $Out -Encoding utf8
    Write-Host "Результаты записаны в $Out"
} else {
    $lines
}
