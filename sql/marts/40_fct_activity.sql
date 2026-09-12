-- =============================================================================
-- marts/40_fct_activity.sql — продуктовая активность по дням и неделям
--
-- Сырой лог событий слишком дорог, чтобы гонять по нему каждый отчёт: 400 тысяч
-- строк и группировка по пользователю в каждом запросе. Здесь он один раз
-- сворачивается до «пользователь × день» и «пользователь × неделя».
--
-- Отдельно считаются «целевые действия» (создание проекта, создание и закрытие
-- задачи). Вход в систему без единого целевого действия — не признак жизни:
-- люди заходят посмотреть и уходят, а метрика удержания на сессиях это
-- завышает. Поэтому в витрине есть оба счётчика, и запросы явно выбирают, какой
-- из них используют.
-- =============================================================================

\set ON_ERROR_STOP on

DROP MATERIALIZED VIEW IF EXISTS marts.fct_user_activity_daily CASCADE;

CREATE MATERIALIZED VIEW marts.fct_user_activity_daily AS
SELECT
    e.user_id,
    e.occurred_at::date                          AS activity_date,
    count(*)                                     AS events_cnt,
    count(*) FILTER (
        WHERE e.event_name IN ('project_created','task_created','task_completed')
    )                                            AS core_actions_cnt,
    count(DISTINCT e.event_name)                 AS distinct_events,
    count(*) FILTER (WHERE e.platform = 'mobile') AS mobile_events
FROM app.events e
WHERE e.event_name NOT IN ('signup','email_confirmed')   -- регистрационные, не активность
GROUP BY e.user_id, e.occurred_at::date;

CREATE UNIQUE INDEX fct_activity_daily_pk ON marts.fct_user_activity_daily (user_id, activity_date);
CREATE INDEX fct_activity_daily_date_idx  ON marts.fct_user_activity_daily (activity_date);

COMMENT ON MATERIALIZED VIEW marts.fct_user_activity_daily IS
    'Активность пользователя за день. Регистрационные события исключены: они есть у всех и ничего не различают.';

-- -----------------------------------------------------------------------------

DROP MATERIALIZED VIEW IF EXISTS marts.fct_user_activity_week CASCADE;

-- Недели отсчитываются от ДНЯ РЕГИСТРАЦИИ пользователя, а не по календарю.
-- Это важнее, чем кажется: при нарезке по ISO-неделям нулевая неделя у
-- зарегистрировавшегося в четверг длится четыре дня, а у зарегистрировавшегося
-- в понедельник — семь. В когортной таблице это выглядит как провал нулевой
-- недели и рост первой, и такую «кривую удержания» начинают объяснять
-- продуктовыми причинами, которых нет.
CREATE MATERIALIZED VIEW marts.fct_user_activity_week AS
SELECT
    a.user_id,
    u.cohort_month,
    ((a.activity_date - u.signup_date) / 7)::int                    AS week_index,
    min(a.activity_date)                                            AS week_start,
    sum(a.events_cnt)::int                                          AS events_cnt,
    sum(a.core_actions_cnt)::int                                    AS core_actions_cnt,
    count(*)::int                                                   AS active_days
FROM marts.fct_user_activity_daily a
JOIN marts.dim_user u USING (user_id)
WHERE a.activity_date >= u.signup_date
GROUP BY a.user_id, u.cohort_month, ((a.activity_date - u.signup_date) / 7)::int;

CREATE UNIQUE INDEX fct_activity_week_pk  ON marts.fct_user_activity_week (user_id, week_index);
CREATE INDEX fct_activity_week_cohort_idx ON marts.fct_user_activity_week (cohort_month, week_index);

COMMENT ON MATERIALIZED VIEW marts.fct_user_activity_week IS
    'Активность по неделям жизни пользователя. Основа для кривых удержания.';
COMMENT ON COLUMN marts.fct_user_activity_week.week_index IS
    'Номер недели жизни: 0 — первые семь суток с момента регистрации, а не календарная неделя.';
