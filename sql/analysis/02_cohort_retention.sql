-- =============================================================================
-- 02 — Удержание: продуктовое по неделям и денежное по месяцам
--
-- Две разные вещи, которые часто путают:
--   • удержание пользователей — сколько из зарегистрировавшихся всё ещё что-то
--     делают в продукте на N-й неделе;
--   • удержание выручки (NRR) — сколько денег осталось от когорты платящих
--     через N месяцев с учётом апгрейдов.
-- NRR может быть выше 100 % при падающем удержании пользователей: меньше
-- клиентов, но оставшиеся платят больше. Поэтому смотреть надо оба.
--
-- Главная ловушка — незрелые ячейки. Когорта, зарегистрировавшаяся три недели
-- назад, физически не может показать удержание восьмой недели. Если её не
-- отсечь, среднее по столбцу поедет вниз, и это прочитают как ухудшение
-- продукта. Ниже такие ячейки отсекаются явным условием на дату.
-- =============================================================================

\pset border 2

\echo ''
\echo '=== 2.1 Недельное удержание по когортам регистрации (целевые действия) ==='
-- Активной считается неделя, на которой пользователь создал или закрыл хотя бы
-- одну задачу либо создал проект. Просто вход в систему не в счёт: заход
-- посмотреть и уйти не отличает живого клиента от умирающего.

WITH cohort_size AS (
    SELECT cohort_month, count(*) AS users
    FROM marts.dim_user
    GROUP BY cohort_month
),
activity AS (
    SELECT
        cohort_month,
        week_index,
        count(DISTINCT user_id) AS active_users
    FROM marts.fct_user_activity_week
    WHERE week_index BETWEEN 0 AND 8
      AND core_actions_cnt > 0
    GROUP BY cohort_month, week_index
),
grid AS (
    SELECT
        c.cohort_month,
        c.users,
        a.week_index,
        a.active_users,
        -- Ячейка зрелая, только если N-я неделя успела пройти целиком даже у
        -- самого позднего пользователя когорты — то есть у зарегистрировавшегося
        -- в последний день месяца. Отсюда «+1 месяц» в условии.
        (c.cohort_month + interval '1 month'
            + (a.week_index + 1) * 7 * interval '1 day') <= marts.snapshot_ts()
            AS is_mature
    FROM cohort_size c
    JOIN activity a USING (cohort_month)
)
SELECT
    to_char(cohort_month, 'YYYY-MM')                                          AS "Когорта",
    users                                                                     AS "Регистраций",
    max(round(100.0 * active_users / users, 1)) FILTER (WHERE week_index = 0 AND is_mature) AS "Н0",
    max(round(100.0 * active_users / users, 1)) FILTER (WHERE week_index = 1 AND is_mature) AS "Н1",
    max(round(100.0 * active_users / users, 1)) FILTER (WHERE week_index = 2 AND is_mature) AS "Н2",
    max(round(100.0 * active_users / users, 1)) FILTER (WHERE week_index = 4 AND is_mature) AS "Н4",
    max(round(100.0 * active_users / users, 1)) FILTER (WHERE week_index = 8 AND is_mature) AS "Н8"
FROM grid
GROUP BY cohort_month, users
ORDER BY cohort_month;

\echo ''
\echo '=== 2.2 Кривая удержания: активировавшиеся против остальных ==='
-- Тот же расчёт, но когорты нарезаны не по времени, а по признаку активации.
-- Если разрыв не схлопывается к восьмой неделе, активация — не разовый всплеск
-- интереса, а устойчивое различие.

WITH base AS (
    SELECT user_id, is_activated FROM marts.dim_user
    WHERE observed_days >= 63          -- 9 недель: все ячейки ниже зрелые
),
sizes AS (
    SELECT is_activated, count(*) AS users FROM base GROUP BY is_activated
),
activity AS (
    SELECT b.is_activated, w.week_index, count(DISTINCT w.user_id) AS active_users
    FROM marts.fct_user_activity_week w
    JOIN base b USING (user_id)
    WHERE w.week_index BETWEEN 0 AND 8 AND w.core_actions_cnt > 0
    GROUP BY b.is_activated, w.week_index
)
SELECT
    a.week_index                                              AS "Неделя",
    max(round(100.0 * a.active_users / s.users, 1)) FILTER (WHERE a.is_activated)       AS "Активированные, %",
    max(round(100.0 * a.active_users / s.users, 1)) FILTER (WHERE NOT a.is_activated)   AS "Остальные, %",
    round(max(100.0 * a.active_users / s.users) FILTER (WHERE a.is_activated)
        - max(100.0 * a.active_users / s.users) FILTER (WHERE NOT a.is_activated), 1)   AS "Разрыв, п.п."
FROM activity a
JOIN sizes s USING (is_activated)
GROUP BY a.week_index
ORDER BY a.week_index;

\echo ''
\echo '=== 2.3 Удержание выручки (NRR) по когортам первой оплаты ==='
-- База когорты — MRR в момент первой оплаты. Значения выше 100 % означают, что
-- апгрейды оставшихся перекрыли потери от ушедших.

WITH cohort_base AS (
    SELECT
        paid_cohort_month,
        count(DISTINCT subscription_id) AS subs,
        sum(first_mrr_rub)              AS base_mrr
    FROM marts.fct_subscription
    WHERE is_converted
    GROUP BY paid_cohort_month
),
by_month AS (
    SELECT
        paid_cohort_month,
        month_index,
        sum(mrr_rub) AS mrr
    FROM marts.fct_subscription_month
    WHERE month_index BETWEEN 0 AND 6
    GROUP BY paid_cohort_month, month_index
),
grid AS (
    SELECT
        b.paid_cohort_month,
        c.subs,
        c.base_mrr,
        b.month_index,
        b.mrr,
        (b.paid_cohort_month + (b.month_index + 1) * interval '1 month') <= marts.snapshot_ts()
            AS is_mature
    FROM by_month b
    JOIN cohort_base c USING (paid_cohort_month)
)
SELECT
    to_char(paid_cohort_month, 'YYYY-MM')                                           AS "Когорта",
    subs                                                                            AS "Подписок",
    round(base_mrr)                                                                 AS "MRR старта, ₽",
    max(round(100.0 * mrr / base_mrr, 1)) FILTER (WHERE month_index = 1 AND is_mature) AS "М1",
    max(round(100.0 * mrr / base_mrr, 1)) FILTER (WHERE month_index = 3 AND is_mature) AS "М3",
    max(round(100.0 * mrr / base_mrr, 1)) FILTER (WHERE month_index = 6 AND is_mature) AS "М6"
FROM grid
GROUP BY paid_cohort_month, subs, base_mrr
ORDER BY paid_cohort_month;

\echo ''
\echo '=== 2.4 Средняя кривая NRR по зрелым когортам ==='
-- Свод строкой: берутся только когорты, дожившие до шестого месяца, поэтому
-- все шесть точек считаются по одному и тому же составу подписок.

WITH mature_cohorts AS (
    SELECT paid_cohort_month
    FROM marts.fct_subscription
    WHERE is_converted
    GROUP BY paid_cohort_month
    HAVING paid_cohort_month + interval '7 months' <= marts.snapshot_ts()
),
base AS (
    SELECT sum(first_mrr_rub) AS base_mrr
    FROM marts.fct_subscription
    WHERE is_converted AND paid_cohort_month IN (SELECT paid_cohort_month FROM mature_cohorts)
)
SELECT
    m.month_index                                       AS "Месяц",
    round(sum(m.mrr_rub))                               AS "MRR, ₽",
    round(100.0 * sum(m.mrr_rub) / max(b.base_mrr), 1)  AS "NRR, %",
    count(DISTINCT m.subscription_id)                   AS "Живых подписок"
FROM marts.fct_subscription_month m
CROSS JOIN base b
WHERE m.paid_cohort_month IN (SELECT paid_cohort_month FROM mature_cohorts)
  AND m.month_index BETWEEN 0 AND 6
GROUP BY m.month_index
ORDER BY m.month_index;
