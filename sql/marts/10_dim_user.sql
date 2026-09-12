-- =============================================================================
-- marts/10_dim_user.sql — карточка пользователя: когорта, канал, воронка, активация
--
-- Одна строка на зарегистрированного пользователя. Сюда сведены все даты
-- прохождения воронки, чтобы аналитические запросы не пересобирали их заново
-- каждый раз из 400 тысяч событий.
--
-- КЛЮЧЕВОЕ ОПРЕДЕЛЕНИЕ. Активация = за первые 7 дней создан хотя бы один проект
-- И создано не меньше трёх задач. Порог в три задачи не выдуман: это первая
-- точка, где кривая удержания заметно расходится (см. docs/metrics.md).
-- Определение живёт здесь и только здесь — все остальные запросы ссылаются
-- на marts.dim_user.is_activated, а не переписывают условие руками.
-- =============================================================================

\set ON_ERROR_STOP on

DROP MATERIALIZED VIEW IF EXISTS marts.dim_user CASCADE;

CREATE MATERIALIZED VIEW marts.dim_user AS
WITH first_week AS (
    -- события первых семи дней: один проход по логу вместо шести коррелированных подзапросов
    SELECT
        u.user_id,
        min(e.occurred_at) FILTER (WHERE e.event_name = 'email_confirmed')       AS email_confirmed_at,
        min(e.occurred_at) FILTER (WHERE e.event_name = 'onboarding_completed')  AS onboarding_completed_at,
        min(e.occurred_at) FILTER (WHERE e.event_name = 'project_created')       AS first_project_at,
        count(*)           FILTER (WHERE e.event_name = 'task_created')          AS tasks_first_7d,
        count(*)           FILTER (WHERE e.event_name = 'invite_sent')           AS invites_first_7d,
        count(*)           FILTER (WHERE e.event_name = 'integration_connected') AS integrations_first_7d
    FROM app.users u
    LEFT JOIN marts.stg_events e
           ON e.user_id = u.user_id
          AND e.occurred_at < u.signed_up_at + interval '7 days'
    GROUP BY u.user_id
),
first_paid AS (
    SELECT
        s.user_id,
        min(s.started_at)                                    AS first_paid_at,
        min(s.subscription_id) FILTER (WHERE s.started_at IS NOT NULL) AS first_paid_subscription_id
    FROM app.subscriptions s
    WHERE s.started_at IS NOT NULL
    GROUP BY s.user_id
),
last_seen AS (
    SELECT user_id, max(occurred_at) AS last_event_at, count(*) AS events_lifetime
    FROM marts.stg_events
    GROUP BY user_id
)
SELECT
    u.user_id,
    u.signed_up_at,
    u.signed_up_at::date                                     AS signup_date,
    date_trunc('week',  u.signed_up_at)::date                AS cohort_week,
    date_trunc('month', u.signed_up_at)::date                AS cohort_month,

    c.channel_code,
    c.channel_name,
    c.channel_group,
    c.cac_rub,

    u.country_code,
    u.company_size,
    u.is_b2b,

    fw.email_confirmed_at,
    fw.onboarding_completed_at,
    fw.first_project_at,
    fw.tasks_first_7d,
    fw.invites_first_7d,
    fw.integrations_first_7d,

    -- то самое определение активации
    (fw.first_project_at IS NOT NULL AND fw.tasks_first_7d >= 3) AS is_activated,

    fp.first_paid_at,
    fp.first_paid_subscription_id,
    (fp.first_paid_at IS NOT NULL)                           AS is_converted,

    ls.last_event_at,
    coalesce(ls.events_lifetime, 0)                          AS events_lifetime,

    -- сколько дней пользователь наблюдался к дате среза
    extract(day FROM (SELECT snapshot_ts FROM marts.meta) - u.signed_up_at)::int AS observed_days,

    -- Успел ли пользователь пройти всю развилку «триал → решение». Триал длится
    -- 14 дней, плюс запас на отложенную оплату. Без этого фильтра конверсия
    -- последних недель всегда занижена: люди ещё внутри триала, а в знаменатель
    -- уже попали. Все запросы, где считается конверсия, фильтруют по этому полю.
    (u.signed_up_at < (SELECT snapshot_ts FROM marts.meta) - interval '30 days') AS is_matured
FROM app.users      u
JOIN app.channels   c  USING (channel_id)
JOIN first_week     fw USING (user_id)
LEFT JOIN first_paid fp USING (user_id)
LEFT JOIN last_seen  ls USING (user_id)
-- Служебные аккаунты сотрудников в продуктовую аналитику не попадают: они
-- заходят в продукт и никогда не платят, то есть тянут конверсию вниз, ничего
-- не говоря о клиентах. Фильтр стоит здесь, в единственной точке входа в
-- пользовательский слой, а не в каждом отчёте по отдельности.
WHERE c.channel_code <> 'internal';

CREATE UNIQUE INDEX dim_user_pk           ON marts.dim_user (user_id);
CREATE INDEX        dim_user_cohort_idx   ON marts.dim_user (cohort_month);
CREATE INDEX        dim_user_channel_idx  ON marts.dim_user (channel_code);
CREATE INDEX        dim_user_activated_idx ON marts.dim_user (is_activated);

COMMENT ON MATERIALIZED VIEW marts.dim_user IS
    'Карточка пользователя: когорта, канал, прохождение воронки, флаги активации и конверсии.';
COMMENT ON COLUMN marts.dim_user.is_activated IS
    'Активация: за 7 дней создан проект И не меньше трёх задач. Единственное место, где задано определение.';
COMMENT ON COLUMN marts.dim_user.cac_rub IS
    'Плановый CAC канала на одну регистрацию. Для расчёта CAC на платящего делится на конверсию.';
