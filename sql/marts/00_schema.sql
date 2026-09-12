-- =============================================================================
-- marts/00_schema.sql — схема витрин, дата среза, календарь
--
-- Схема marts — слой, на который смотрит аналитик. Всё, что здесь лежит,
-- пересчитывается из app одной командой и не хранит собственных правок.
-- =============================================================================

\set ON_ERROR_STOP on

DROP SCHEMA IF EXISTS marts CASCADE;
CREATE SCHEMA marts;

COMMENT ON SCHEMA marts IS
    'Витрины поверх сырого слоя app. Пересобираются скриптами sql/marts/*.sql.';

-- -----------------------------------------------------------------------------
-- Дата среза
--
-- Выгрузка обрывается в конкретный момент, и половина метрик от него зависит:
-- «активна сейчас», «дней с последнего входа», «когорта ещё не дожила до 6 месяца».
-- Держим её в одной функции, а не размазываем now() по два десятка запросов —
-- иначе завтра те же запросы дадут другие числа, и кейс перестанет быть
-- воспроизводимым.
-- -----------------------------------------------------------------------------

CREATE MATERIALIZED VIEW marts.meta AS
SELECT date_trunc('day', max(occurred_at)) + interval '1 day' AS snapshot_ts
FROM app.events;

COMMENT ON MATERIALIZED VIEW marts.meta IS
    'Одна строка: момент выгрузки. Материализована намеренно — см. комментарий к snapshot_ts().';

CREATE FUNCTION marts.snapshot_ts() RETURNS timestamp
LANGUAGE sql STABLE AS $$
    SELECT snapshot_ts FROM marts.meta
$$;

COMMENT ON FUNCTION marts.snapshot_ts() IS
    'Момент выгрузки данных. Выводится из данных, а не из now() — ради воспроизводимости.';

-- Почему функция читает материализованную витрину, а не считает max() сама.
-- STABLE-функция в списке выборки вычисляется заново на КАЖДОЙ строке. Если
-- внутри стоит max(occurred_at) по app.events, построение dim_user на 12 тысяч
-- пользователей превращается в 12 тысяч полных проходов по 400 тысячам событий
-- и не заканчивается за разумное время. Проверено дорогой ценой. С одной
-- строкой в marts.meta та же функция стоит копейки.

-- -----------------------------------------------------------------------------
-- Календарь
-- -----------------------------------------------------------------------------

CREATE MATERIALIZED VIEW marts.dim_date AS
SELECT
    d::date                                            AS date_day,
    date_trunc('week',  d)::date                       AS date_week,
    date_trunc('month', d)::date                       AS date_month,
    date_trunc('quarter', d)::date                     AS date_quarter,
    extract(isodow FROM d)::smallint                   AS day_of_week,
    extract(isodow FROM d) >= 6                        AS is_weekend,
    to_char(d, 'YYYY-MM')                              AS month_label
FROM generate_series(
        (SELECT date_trunc('month', min(signed_up_at)) FROM app.users),
        marts.snapshot_ts(),
        interval '1 day'
     ) AS d;

CREATE UNIQUE INDEX dim_date_pk ON marts.dim_date (date_day);

COMMENT ON MATERIALIZED VIEW marts.dim_date IS
    'Календарь от первой регистрации до даты среза. Нужен, чтобы дни без событий не выпадали из рядов.';
