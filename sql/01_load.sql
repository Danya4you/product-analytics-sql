-- =============================================================================
-- 01_load.sql — загрузка CSV из data/ в схему app
--
-- Запускать psql ИЗ КОРНЯ репозитория: \copy читает файлы относительно каталога,
-- где запущен клиент, а не сервер.
--
--     psql -U postgres -d timeline_analytics -f sql/01_load.sql
--
-- Порядок таблиц продиктован внешними ключами. Пустая строка в CSV означает
-- NULL (null ''), поэтому даты без значения не превращаются в ошибку.
-- =============================================================================

\set ON_ERROR_STOP on

-- \copy читает файл клиентом и перекодирует его из client_encoding в кодировку
-- базы. В консоли Windows client_encoding по умолчанию WIN1251, и тогда
-- UTF-8-байты из CSV считаются однобайтовой кириллицей и уезжают в базу
-- дважды перекодированными: «Реферальная программа» превращается в
-- «Р РµС„РµСЂР°Р»СЊРЅР°СЏ». Ошибки при этом не возникает — просто мусор в справочниках.
\encoding UTF8

BEGIN;

TRUNCATE app.experiment_assignments, app.experiments, app.events, app.payments,
         app.subscription_events, app.subscriptions, app.users,
         app.channels, app.plans
    RESTART IDENTITY CASCADE;

\copy app.plans        FROM 'data/plans.csv'        WITH (FORMAT csv, HEADER true, NULL '')
\copy app.channels     FROM 'data/channels.csv'     WITH (FORMAT csv, HEADER true, NULL '')
\copy app.users        FROM 'data/users.csv'        WITH (FORMAT csv, HEADER true, NULL '')
\copy app.subscriptions FROM 'data/subscriptions.csv' WITH (FORMAT csv, HEADER true, NULL '')
\copy app.subscription_events FROM 'data/subscription_events.csv' WITH (FORMAT csv, HEADER true, NULL '')
\copy app.payments     FROM 'data/payments.csv'     WITH (FORMAT csv, HEADER true, NULL '')
\copy app.events       FROM 'data/events.csv'       WITH (FORMAT csv, HEADER true, NULL '')
\copy app.experiments  FROM 'data/experiments.csv'  WITH (FORMAT csv, HEADER true, NULL '')
\copy app.experiment_assignments FROM 'data/experiment_assignments.csv' WITH (FORMAT csv, HEADER true, NULL '')

COMMIT;

-- Планировщику нужна свежая статистика: без ANALYZE первые же оконные запросы
-- по app.events уходят в seq scan на 400 тысячах строк.
ANALYZE app.users, app.subscriptions, app.subscription_events, app.payments, app.events;

\echo ''
\echo 'Загружено:'
SELECT 'users' AS table_name, count(*) AS rows FROM app.users
UNION ALL SELECT 'subscriptions',       count(*) FROM app.subscriptions
UNION ALL SELECT 'subscription_events', count(*) FROM app.subscription_events
UNION ALL SELECT 'payments',            count(*) FROM app.payments
UNION ALL SELECT 'events',              count(*) FROM app.events
UNION ALL SELECT 'experiment_assignments', count(*) FROM app.experiment_assignments
ORDER BY 1;
