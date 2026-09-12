-- =============================================================================
-- scripts/explain.sql — замеры, на которых основан docs/performance.md
--
--     psql -d timeline_analytics -f scripts/explain.sql > report/explain.txt
--
-- Три случая, где выбор формулировки запроса меняет время на порядки. Каждый
-- прогоняется в двух вариантах — медленном и быстром, — чтобы разница была
-- измерена, а не заявлена.
--
-- Замеры зависят от машины и от состояния кеша; интересны не абсолютные
-- миллисекунды, а отношение между вариантами.
-- =============================================================================

\set ON_ERROR_STOP on
\pset pager off

\echo ''
\echo '################################################################'
\echo '# 1. STABLE-функция в списке выборки'
\echo '################################################################'
\echo ''
\echo 'Функция, которая честно считает max() по app.events, вычисляется на'
\echo 'КАЖДОЙ строке результата. Ниже она берётся всего для 200 пользователей.'
\echo 'Умножьте на 60, чтобы получить время построения dim_user на 12 000.'
\echo ''

CREATE FUNCTION pg_temp.naive_snapshot() RETURNS timestamp
LANGUAGE sql STABLE AS $$
    SELECT date_trunc('day', max(occurred_at)) + interval '1 day' FROM app.events
$$;

\echo '--- наивная версия (полный проход по событиям на каждую строку) ---'
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY ON)
SELECT u.user_id, pg_temp.naive_snapshot() - u.signed_up_at AS age
FROM (SELECT * FROM app.users ORDER BY user_id LIMIT 200) u;

\echo ''
\echo '--- версия из репозитория (чтение витрины marts.meta из одной строки) ---'
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY ON)
SELECT u.user_id, marts.snapshot_ts() - u.signed_up_at AS age
FROM (SELECT * FROM app.users ORDER BY user_id LIMIT 200) u;

\echo ''
\echo '################################################################'
\echo '# 2. Коррелированный подзапрос против предварительной свёртки'
\echo '################################################################'
\echo ''
\echo 'Задача: медиана числа событий каждого типа на аккаунт. Первый вариант'
\echo 'на каждой строке лога спрашивает «а сколько таких у этого пользователя»,'
\echo 'второй сначала сворачивает лог до «пользователь x событие».'
\echo 'Окно сужено до 30 дней, иначе наивный вариант не дожидается.'
\echo ''

\echo '--- наивный: подзапрос на каждой строке ---'
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY ON)
SELECT e.event_name,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY per_user.cnt) AS median
FROM marts.stg_events e
JOIN LATERAL (
    SELECT count(*) AS cnt FROM marts.stg_events x
    WHERE x.user_id = e.user_id AND x.event_name = e.event_name
      AND x.occurred_at > marts.snapshot_ts() - interval '30 days'
) per_user ON true
WHERE e.occurred_at > marts.snapshot_ts() - interval '30 days'
GROUP BY e.event_name;

\echo ''
\echo '--- из репозитория: сначала свёртка, потом медиана ---'
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY ON)
WITH per_user AS (
    SELECT user_id, event_name, count(*) AS cnt
    FROM marts.stg_events
    WHERE occurred_at > marts.snapshot_ts() - interval '30 days'
    GROUP BY user_id, event_name
)
SELECT event_name, percentile_cont(0.5) WITHIN GROUP (ORDER BY cnt) AS median
FROM per_user GROUP BY event_name;

\echo ''
\echo '################################################################'
\echo '# 3. Когда индекс на (user_id, occurred_at) работает, а когда нет'
\echo '################################################################'
\echo ''
\echo 'Индекс — не универсальное ускорение, а выбор планировщика. Ниже два'
\echo 'запроса к одной таблице: в первом индекс используется, во втором'
\echo 'планировщик от него отказывается, и правильно делает.'
\echo ''

\echo '--- 3a. Один пользователь: индексный доступ ---'
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY ON)
SELECT count(*) FILTER (WHERE event_name = 'task_created') AS tasks
FROM marts.stg_events
WHERE user_id = 4242
  AND occurred_at < timestamp '2026-01-01';

\echo ''
\echo '--- 3b. Все пользователи разом: планировщик берёт последовательное чтение ---'
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY ON)
SELECT u.user_id,
       count(*) FILTER (WHERE e.event_name = 'task_created') AS tasks
FROM app.users u
LEFT JOIN marts.stg_events e
       ON e.user_id = u.user_id
      AND e.occurred_at < u.signed_up_at + interval '7 days'
GROUP BY u.user_id;

\echo ''
\echo '--- 3c. Тот же запрос с принудительно запрещённым индексом ---'
\echo '    Если время почти не изменилось — значит индекс и не использовался.'
SET enable_indexscan = off;
SET enable_bitmapscan = off;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY ON)
SELECT u.user_id,
       count(*) FILTER (WHERE e.event_name = 'task_created') AS tasks
FROM app.users u
LEFT JOIN marts.stg_events e
       ON e.user_id = u.user_id
      AND e.occurred_at < u.signed_up_at + interval '7 days'
GROUP BY u.user_id;
RESET enable_indexscan;
RESET enable_bitmapscan;

\echo ''
\echo 'Готово.'
