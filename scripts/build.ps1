# =============================================================================
# Сборка витрины под Windows. То же, что scripts/build.sh, но для PowerShell.
#
#   .\scripts\build.ps1
#   .\scripts\build.ps1 -Users 4000
#   .\scripts\build.ps1 -PsqlPath 'C:\Program Files\PostgreSQL\17\bin\psql.exe'
#
# Пароль берётся из переменной окружения PGPASSWORD; если её нет, psql спросит.
# =============================================================================
param(
    [int]    $Users    = 12000,
    [string] $Database = $(if ($env:PGDATABASE) { $env:PGDATABASE } else { 'timeline_analytics' }),
    [string] $PsqlPath = 'psql',
    [string] $Python   = 'python'
)

$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

# Без этого \copy прочитает UTF-8-файлы как WIN1251 и кириллица в справочниках
# попадёт в базу дважды перекодированной.
$env:PGCLIENTENCODING = 'UTF8'

if ($PsqlPath -eq 'psql' -and -not (Get-Command psql -ErrorAction SilentlyContinue)) {
    $found = Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin\psql.exe' -ErrorAction SilentlyContinue |
             Sort-Object FullName -Descending | Select-Object -First 1
    if ($found) {
        $PsqlPath = $found.FullName
        Write-Host "psql найден: $PsqlPath" -ForegroundColor DarkGray
    } else {
        throw 'psql не найден. Укажите путь параметром -PsqlPath.'
    }
}

$psqlArgs = @('--quiet', '--no-psqlrc', '-v', 'ON_ERROR_STOP=1')

function Step($text) { Write-Host "`n==> $text" -ForegroundColor Cyan }

function Invoke-Psql {
    param([string] $Db, [string[]] $Extra)
    & $PsqlPath -d $Db @psqlArgs @Extra
    if ($LASTEXITCODE -ne 0) { throw "psql завершился с кодом $LASTEXITCODE" }
}

Step "Генерация данных ($Users регистраций)"
& $Python etl/generate_data.py --users $Users
if ($LASTEXITCODE -ne 0) { throw 'Генератор данных завершился с ошибкой' }

Step "База $Database"
$exists = & $PsqlPath -d postgres @psqlArgs -tAc "SELECT 1 FROM pg_database WHERE datname = '$Database'"
if ($exists -ne '1') {
    Invoke-Psql -Db postgres -Extra @('-c', "CREATE DATABASE ""$Database"" ENCODING 'UTF8' TEMPLATE template0")
    Write-Host 'создана'
} else {
    Write-Host 'уже существует'
}

Step 'Схема сырого слоя'
Invoke-Psql -Db $Database -Extra @('-f', 'sql/00_schema.sql')

Step 'Загрузка CSV'
Invoke-Psql -Db $Database -Extra @('-f', 'sql/01_load.sql')

Step 'Витрины'
foreach ($f in Get-ChildItem sql/marts/*.sql | Sort-Object Name) {
    Write-Host "  $($f.Name)"
    Invoke-Psql -Db $Database -Extra @('-f', "sql/marts/$($f.Name)")
}

Step 'Проверки качества'
Invoke-Psql -Db $Database -Extra @('-f', 'tests/data_quality.sql')

Write-Host "`nГотово." -ForegroundColor Green
Write-Host "Запустить анализ: .\scripts\run_analysis.ps1"
