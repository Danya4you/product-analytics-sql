#!/usr/bin/env bash
# =============================================================================
# Прогон всех аналитических запросов. Без аргументов выводит результаты в
# консоль; с аргументом — складывает в указанный файл.
#
#   ./scripts/run_analysis.sh                      # на экран
#   ./scripts/run_analysis.sh report/output.txt    # в файл
#   ./scripts/run_analysis.sh '' 05                # только запрос 05
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."

OUT="${1:-}"
ONLY="${2:-}"
DB="${PGDATABASE:-timeline_analytics}"
export PGCLIENTENCODING=UTF8

run_all() {
    for f in sql/analysis/*.sql; do
        [[ -n "$ONLY" && "$(basename "$f")" != "$ONLY"* ]] && continue
        printf '\n\n'
        printf '########################################################################\n'
        printf '# %s\n' "$(basename "$f")"
        printf '########################################################################\n'
        psql -d "$DB" --quiet --no-psqlrc -v ON_ERROR_STOP=1 -f "$f"
    done
}

if [[ -n "$OUT" ]]; then
    mkdir -p "$(dirname "$OUT")"
    run_all > "$OUT"
    echo "Результаты записаны в $OUT"
else
    run_all
fi
