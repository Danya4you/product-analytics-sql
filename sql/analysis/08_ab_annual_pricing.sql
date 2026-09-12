-- =============================================================================
-- 08 — A/B-тест «Годовой тариф по умолчанию»
--
-- Гипотеза: если на странице тарифов период по умолчанию — годовой, вырастет
-- доля годовых подписок и денежный поток, а конверсия в оплату не пострадает.
--
-- Тест с двумя разнонаправленными метриками — самый неудобный случай для
-- аналитика, и именно поэтому он здесь. Годовая подписка приносит деньги
-- сразу и держится дольше, но платить за год вперёд готовы не все, и часть
-- сомневающихся вместо этого не платит вовсе. Ответ «выкатываем» или «нет»
-- зависит от того, что дороже компании — деньги сейчас или число клиентов.
-- =============================================================================

\pset border 2
\set exp_code 'annual_first_pricing'

\echo ''
\echo '=== 8.1 Паспорт эксперимента ==='

SELECT
    experiment_name                     AS "Эксперимент",
    to_char(started_at, 'DD.MM.YYYY')   AS "Начало",
    to_char(ended_at,   'DD.MM.YYYY')   AS "Конец",
    primary_metric                      AS "Основная метрика",
    hypothesis                          AS "Гипотеза"
FROM app.experiments
WHERE experiment_code = :'exp_code';

\echo ''
\echo '=== 8.2 Доли: конверсия и выбор годового тарифа ==='
-- Знаменатель у метрик РАЗНЫЙ, и это не опечатка. Конверсия считается от всех
-- попавших в эксперимент, доля годовых — только от оплативших: показать
-- годовой тариф по умолчанию можно кому угодно, а выбрать его может лишь тот,
-- кто дошёл до оплаты.

WITH assigned AS (
    SELECT a.variant, u.user_id, u.is_converted, u.is_matured
    FROM app.experiment_assignments a
    JOIN app.experiments e USING (experiment_id)
    JOIN marts.dim_user u ON u.user_id = a.user_id
    WHERE e.experiment_code = :'exp_code' AND u.is_matured
),
paid AS (
    SELECT a.variant, s.first_billing_period, s.first_mrr_rub, s.first_plan_name,
           p.amount_rub AS first_payment
    FROM assigned a
    JOIN marts.fct_subscription s ON s.user_id = a.user_id AND s.is_converted
    LEFT JOIN LATERAL (
        SELECT amount_rub FROM app.payments
        WHERE subscription_id = s.subscription_id AND status = 'succeeded'
        ORDER BY paid_at LIMIT 1
    ) p ON true
),
metrics AS (
    SELECT 1 AS ord, 'Конверсия в оплату (от всех)' AS metric,
           count(*) FILTER (WHERE variant = 'control')                    AS n1,
           count(*) FILTER (WHERE variant = 'control'   AND is_converted) AS x1,
           count(*) FILTER (WHERE variant = 'treatment')                  AS n2,
           count(*) FILTER (WHERE variant = 'treatment' AND is_converted) AS x2
    FROM assigned
    UNION ALL
    SELECT 2, '* Доля годовых (от оплативших)',
           count(*) FILTER (WHERE variant = 'control'),
           count(*) FILTER (WHERE variant = 'control'   AND first_billing_period = 'annual'),
           count(*) FILTER (WHERE variant = 'treatment'),
           count(*) FILTER (WHERE variant = 'treatment' AND first_billing_period = 'annual')
    FROM paid
)
SELECT
    metric                                                           AS "Метрика",
    n1                                                               AS "n контроль",
    n2                                                               AS "n тест",
    round(100.0 * x1 / nullif(n1, 0), 1)                             AS "Контроль, %",
    round(100.0 * x2 / nullif(n2, 0), 1)                             AS "Тест, %",
    round(100.0 * x2 / nullif(n2, 0) - 100.0 * x1 / nullif(n1, 0), 1) AS "Разница, п.п.",
    round((100 * marts.ci95_diff_proportions(x1, n1, x2, n2, 'low'))::numeric, 1)  AS "ДИ снизу",
    round((100 * marts.ci95_diff_proportions(x1, n1, x2, n2, 'high'))::numeric, 1) AS "ДИ сверху",
    round(marts.p_value_two_sided(marts.z_two_proportions(x1, n1, x2, n2))::numeric, 4) AS "p",
    CASE WHEN marts.p_value_two_sided(marts.z_two_proportions(x1, n1, x2, n2)) < 0.05
         THEN 'значимо' ELSE 'не значимо' END                        AS "При α = 0,05"
FROM metrics
ORDER BY ord;

\echo ''
\echo '=== 8.3 Деньги: первый платёж и MRR ==='
-- Средние сравниваются z-приближением (n в сотнях, нормальность средних
-- обеспечена ЦПТ). Дисперсии у групп разные — объединять их нельзя, поэтому
-- стандартная ошибка считается как у Уэлча: корень из суммы s²/n по группам.

WITH assigned AS (
    SELECT a.variant, u.user_id
    FROM app.experiment_assignments a
    JOIN app.experiments e USING (experiment_id)
    JOIN marts.dim_user u ON u.user_id = a.user_id
    WHERE e.experiment_code = :'exp_code' AND u.is_matured
),
paid AS (
    SELECT a.variant, s.first_mrr_rub,
           coalesce(p.amount_rub, 0) AS first_payment
    FROM assigned a
    JOIN marts.fct_subscription s ON s.user_id = a.user_id AND s.is_converted
    LEFT JOIN LATERAL (
        SELECT amount_rub FROM app.payments
        WHERE subscription_id = s.subscription_id AND status = 'succeeded'
        ORDER BY paid_at LIMIT 1
    ) p ON true
),
stats AS (
    SELECT 1 AS ord, 'Первый платёж, ₽' AS metric,
           avg(first_payment)    FILTER (WHERE variant = 'control')   AS m1,
           stddev_samp(first_payment) FILTER (WHERE variant = 'control')   AS s1,
           count(*)              FILTER (WHERE variant = 'control')   AS n1,
           avg(first_payment)    FILTER (WHERE variant = 'treatment') AS m2,
           stddev_samp(first_payment) FILTER (WHERE variant = 'treatment') AS s2,
           count(*)              FILTER (WHERE variant = 'treatment') AS n2
    FROM paid
    UNION ALL
    SELECT 2, 'MRR подписки, ₽',
           avg(first_mrr_rub)    FILTER (WHERE variant = 'control'),
           stddev_samp(first_mrr_rub) FILTER (WHERE variant = 'control'),
           count(*)              FILTER (WHERE variant = 'control'),
           avg(first_mrr_rub)    FILTER (WHERE variant = 'treatment'),
           stddev_samp(first_mrr_rub) FILTER (WHERE variant = 'treatment'),
           count(*)              FILTER (WHERE variant = 'treatment')
    FROM paid
)
SELECT
    metric                                                     AS "Метрика",
    round(m1)                                                  AS "Контроль",
    round(m2)                                                  AS "Тест",
    round(m2 - m1)                                             AS "Разница",
    round(100 * (m2 - m1) / nullif(m1, 0), 1)                  AS "Разница, %",
    round(((m2 - m1) / nullif(sqrt(s1 * s1 / n1 + s2 * s2 / n2), 0))::numeric, 2) AS "z",
    round(marts.p_value_two_sided(
        ((m2 - m1) / nullif(sqrt(s1 * s1 / n1 + s2 * s2 / n2), 0))::double precision)::numeric, 4)
                                                               AS "p"
FROM stats
ORDER BY ord;

\echo ''
\echo '=== 8.4 Что это значит для денег ==='
-- Сведение эффекта в рубли на 1000 регистраций: единственная форма, в которой
-- разнонаправленные метрики можно сравнить между собой. Денежный поток за
-- первый год считается по фактическому распределению тарифов в каждой группе.

WITH assigned AS (
    SELECT a.variant, u.user_id
    FROM app.experiment_assignments a
    JOIN app.experiments e USING (experiment_id)
    JOIN marts.dim_user u ON u.user_id = a.user_id
    WHERE e.experiment_code = :'exp_code' AND u.is_matured
),
per_variant AS (
    SELECT
        a.variant,
        count(*)                                                 AS signups,
        count(s.subscription_id)                                 AS paying,
        coalesce(sum(s.first_mrr_rub), 0)                        AS mrr_total,
        coalesce(sum(CASE WHEN s.first_billing_period = 'annual'
                          THEN s.first_mrr_rub * 12 ELSE s.first_mrr_rub END), 0) AS cash_upfront
    FROM assigned a
    LEFT JOIN marts.fct_subscription s ON s.user_id = a.user_id AND s.is_converted
    GROUP BY a.variant
)
SELECT
    variant                                              AS "Группа",
    signups                                              AS "Регистраций",
    paying                                               AS "Оплатили",
    round(1000.0 * paying / signups, 1)                  AS "Платящих на 1000",
    round(1000.0 * mrr_total / signups)                  AS "MRR на 1000, ₽",
    round(1000.0 * cash_upfront / signups)               AS "Деньги сразу на 1000, ₽"
FROM per_variant
ORDER BY variant;
