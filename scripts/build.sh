#!/usr/bin/env bash
# =============================================================================
# Полная сборка витрины с нуля: генерация данных, схема, загрузка, витрины,
# проверки качества. Идемпотентна — можно запускать сколько угодно раз.
#
#   ./scripts/build.sh                 # 12 000 регистраций
#   USERS=4000 ./scripts/build.sh      # быстрый прогон
#
# Подключение настраивается стандартными переменными libpq: PGHOST, PGPORT,
# PGUSER, PGPASSWORD. Имя базы — PGDATABASE, по умолчанию timeline_analytics.
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."

USERS="${USERS:-12000}"
DB="${PGDATABASE:-timeline_analytics}"
PSQL_ARGS=(--quiet --no-psqlrc -v ON_ERROR_STOP=1)

# \copy перекодирует файл из client_encoding: без этого кириллица в справочниках
# уедет дважды перекодированной (подробности в sql/01_load.sql).
export PGCLIENTENCODING=UTF8

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

step "Генерация данных ($USERS регистраций)"
python3 etl/generate_data.py --users "$USERS" 2>/dev/null || python etl/generate_data.py --users "$USERS"

step "База $DB"
if ! psql -d postgres "${PSQL_ARGS[@]}" -tAc "SELECT 1 FROM pg_database WHERE datname = '$DB'" | grep -q 1; then
    psql -d postgres "${PSQL_ARGS[@]}" -c "CREATE DATABASE \"$DB\" ENCODING 'UTF8' TEMPLATE template0"
    echo "создана"
else
    echo "уже существует"
fi

step "Схема сырого слоя"
psql -d "$DB" "${PSQL_ARGS[@]}" -f sql/00_schema.sql

step "Загрузка CSV"
psql -d "$DB" "${PSQL_ARGS[@]}" -f sql/01_load.sql

step "Витрины"
for f in sql/marts/*.sql; do
    echo "  $f"
    psql -d "$DB" "${PSQL_ARGS[@]}" -f "$f"
done

step "Проверки качества"
psql -d "$DB" "${PSQL_ARGS[@]}" -f tests/data_quality.sql

printf '\n\033[1mГотово.\033[0m Запустить анализ: ./scripts/run_analysis.sh\n'
