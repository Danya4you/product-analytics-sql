-- =============================================================================
-- 05 — Отток: кто уходит, когда и по каким признакам это видно заранее
--
-- Три разных вопроса, которые обычно сваливают в один:
--   • Кто уходит — какие сегменты отваливаются чаще остальных.
--   • Когда уходят — как риск меняется с возрастом подписки.
--   • Видно ли заранее — есть ли в поведении сигнал за недели до отмены.
--
-- Последний вопрос единственный, который что-то даёт операционно: по первым
-- двум можно только менять правила привлечения, по третьему — вмешаться в
-- конкретную подписку, пока она жива.
-- =============================================================================

\pset border 2

\echo ''
\echo '=== 5.1 Отток по сегментам ==='
-- Месячный отток = ушедшие / суммарное число месяцев под риском. Так считать
-- корректнее, чем «доля ушедших от всех», потому что подписки прожили разное
-- время: сегмент из свежих подписок всегда выглядит стабильнее, чем есть.

WITH segments AS (
    SELECT 'Активация в первую неделю' AS dimension,
           CASE WHEN u.is_activated THEN 'да' ELSE 'нет' END AS segment,
           s.* FROM marts.fct_subscription s JOIN marts.dim_user u USING (user_id)
    UNION ALL
    SELECT 'Период оплаты', s.first_billing_period,
           s.* FROM marts.fct_subscription s
    UNION ALL
    SELECT 'Тариф', s.first_plan_name,
           s.* FROM marts.fct_subscription s
    UNION ALL
    SELECT 'Размер компании', u.company_size,
           s.* FROM marts.fct_subscription s JOIN marts.dim_user u USING (user_id)
)
SELECT
    dimension                                                    AS "Разрез",
    segment                                                      AS "Сегмент",
    count(*)                                                     AS "Подписок",
    count(*) FILTER (WHERE NOT is_active)                        AS "Ушли",
    round(avg(tenure_months), 1)                                 AS "Средний срок, мес",
    round(100.0 * count(*) FILTER (WHERE NOT is_active)
          / nullif(sum(tenure_months), 0), 2)                    AS "Отток, %/мес",
    round(avg(revenue_rub))                                      AS "Выручка на подписку, ₽"
FROM segments
WHERE is_converted
GROUP BY dimension, segment
ORDER BY dimension, "Отток, %/мес";

\echo ''
\echo '=== 5.2 Риск оттока по возрасту подписки ==='
-- Классическая кривая выживания: если риск падает с возрастом, удерживать надо
-- первые месяцы, а не всех подряд. Знаменатель — число подписок, ДОЖИВШИХ до
-- начала месяца, иначе поздние месяцы получат заниженный риск.

WITH months AS (
    SELECT generate_series(1, 12) AS month_no
),
survival AS (
    SELECT
        m.month_no,
        count(*) FILTER (WHERE s.tenure_months >= m.month_no - 1)                       AS at_risk,
        count(*) FILTER (WHERE NOT s.is_active
                           AND s.tenure_months >= m.month_no - 1
                           AND s.tenure_months <  m.month_no)                           AS churned
    FROM months m
    CROSS JOIN marts.fct_subscription s
    WHERE s.is_converted
    GROUP BY m.month_no
)
SELECT
    month_no                                                AS "Месяц жизни",
    at_risk                                                 AS "Дожили",
    churned                                                 AS "Ушли за месяц",
    round(100.0 * churned / nullif(at_risk, 0), 1)          AS "Риск оттока, %",
    round(100.0 * (1 - churned::numeric / nullif(at_risk, 0)), 1) AS "Выжили, %"
FROM survival
ORDER BY month_no;

\echo ''
\echo '=== 5.3 Сигнал в поведении: активность перед отменой ==='
-- Сравниваются два окна по 28 дней подряд. У ушедших они отсчитываются от даты
-- отмены, у живых — от даты среза. Если у ушедших падение заметно глубже,
-- значит отмена не внезапна и у поддержки есть месяц на реакцию.

WITH windows AS (
    SELECT
        s.subscription_id,
        s.user_id,
        s.is_active,
        coalesce(s.ended_at, marts.snapshot_ts()) AS anchor
    FROM marts.fct_subscription s
    WHERE s.is_converted
      -- нужен запас в 56 дней, иначе «предыдущее окно» частично вне жизни подписки
      AND s.tenure_days >= 56
),
activity AS (
    SELECT
        w.subscription_id,
        w.is_active,
        sum(a.core_actions_cnt) FILTER (
            WHERE a.activity_date >  (w.anchor - interval '28 days')::date) AS last_28,
        sum(a.core_actions_cnt) FILTER (
            WHERE a.activity_date <= (w.anchor - interval '28 days')::date
              AND a.activity_date >  (w.anchor - interval '56 days')::date) AS prev_28
    FROM windows w
    LEFT JOIN marts.fct_user_activity_daily a
           ON a.user_id = w.user_id
          AND a.activity_date > (w.anchor - interval '56 days')::date
          AND a.activity_date <= w.anchor::date
    GROUP BY w.subscription_id, w.is_active
)
SELECT
    CASE WHEN is_active THEN 'Живые подписки' ELSE 'Ушедшие подписки' END   AS "Группа",
    count(*)                                                                AS "Подписок",
    round(avg(coalesce(prev_28, 0)), 1)                                     AS "Действий, окно -56..-28",
    round(avg(coalesce(last_28, 0)), 1)                                     AS "Действий, окно -28..0",
    round(100.0 * (avg(coalesce(last_28, 0)) - avg(coalesce(prev_28, 0)))
          / nullif(avg(coalesce(prev_28, 0)), 0), 1)                        AS "Изменение, %",
    round(100.0 * count(*) FILTER (WHERE coalesce(last_28, 0) = 0) / count(*), 1)
                                                                            AS "Полностью замолчали, %"
FROM activity
GROUP BY is_active
ORDER BY is_active;

\echo ''
\echo '=== 5.4 Сколько MRR сейчас в зоне риска ==='
-- Прикладной вывод из 5.3: живые подписки, у которых активность за последние
-- 28 дней упала более чем вдвое или обнулилась. Это список на обзвон, а не
-- метрика для отчёта.

WITH live AS (
    SELECT s.subscription_id, s.user_id, s.current_mrr_rub, s.first_plan_name, u.channel_name
    FROM marts.fct_subscription s
    JOIN marts.dim_user u USING (user_id)
    WHERE s.is_active AND s.tenure_days >= 56
),
activity AS (
    SELECT
        l.subscription_id,
        l.current_mrr_rub,
        l.first_plan_name,
        coalesce(sum(a.core_actions_cnt) FILTER (
            WHERE a.activity_date > (marts.snapshot_ts() - interval '28 days')::date), 0) AS last_28,
        coalesce(sum(a.core_actions_cnt) FILTER (
            WHERE a.activity_date <= (marts.snapshot_ts() - interval '28 days')::date
              AND a.activity_date >  (marts.snapshot_ts() - interval '56 days')::date), 0) AS prev_28
    FROM live l
    LEFT JOIN marts.fct_user_activity_daily a
           ON a.user_id = l.user_id
          AND a.activity_date > (marts.snapshot_ts() - interval '56 days')::date
    GROUP BY l.subscription_id, l.current_mrr_rub, l.first_plan_name
),
flagged AS (
    SELECT *,
        CASE
            WHEN last_28 = 0                       THEN 'Замолчали'
            WHEN last_28 < prev_28 * 0.5           THEN 'Падение больше чем вдвое'
            ELSE                                        'Норма'
        END AS risk_bucket
    FROM activity
)
SELECT
    risk_bucket                                                  AS "Группа риска",
    count(*)                                                     AS "Подписок",
    round(100.0 * count(*) / sum(count(*)) OVER (), 1)           AS "Доля, %",
    round(sum(current_mrr_rub))                                  AS "MRR под риском, ₽",
    round(100.0 * sum(current_mrr_rub) / sum(sum(current_mrr_rub)) OVER (), 1) AS "Доля MRR, %"
FROM flagged
GROUP BY risk_bucket
ORDER BY sum(current_mrr_rub) DESC;
