-- =============================================================================
-- 06 — RFM-сегментация платящих аккаунтов
--
-- Классический RFM придуман для розницы, где есть покупки. У подписочного
-- сервиса покупка одна и повторяется сама, поэтому измерения переопределены:
--
--   R (recency)   — дней с последнего целевого действия в продукте;
--   F (frequency) — активных дней за последние 90;
--   M (monetary)  — текущий MRR подписки.
--
-- Оценки считаются через NTILE(5): важны не абсолютные значения, а место
-- аккаунта относительно остальных. Пороговые значения квинтилей выводятся
-- рядом — без них таблица сегментов не проверяема.
-- =============================================================================

\pset border 2

\echo ''
\echo '=== 6.1 Распределение по сегментам ==='

WITH live AS (
    SELECT
        s.subscription_id,
        s.user_id,
        s.current_mrr_rub,
        u.channel_name,
        u.company_size
    FROM marts.fct_subscription s
    JOIN marts.dim_user u USING (user_id)
    WHERE s.is_active
),
behaviour AS (
    SELECT
        l.subscription_id,
        l.current_mrr_rub,
        l.channel_name,
        -- если целевых действий не было вовсе, ставим потолок в 999 дней:
        -- NULL здесь испортил бы NTILE, свалив таких в лучший квинтиль
        coalesce(
            (marts.snapshot_ts()::date - max(a.activity_date) FILTER (WHERE a.core_actions_cnt > 0)),
            999)                                                        AS recency_days,
        count(*) FILTER (WHERE a.core_actions_cnt > 0
                           AND a.activity_date > (marts.snapshot_ts() - interval '90 days')::date)
                                                                        AS active_days_90
    FROM live l
    LEFT JOIN marts.fct_user_activity_daily a ON a.user_id = l.user_id
    GROUP BY l.subscription_id, l.current_mrr_rub, l.channel_name
),
scored AS (
    SELECT
        *,
        -- для recency меньше значит лучше, поэтому сортировка обратная
        ntile(5) OVER (ORDER BY recency_days DESC)   AS r_score,
        ntile(5) OVER (ORDER BY active_days_90)      AS f_score,
        ntile(5) OVER (ORDER BY current_mrr_rub)     AS m_score
    FROM behaviour
),
segmented AS (
    SELECT *,
        CASE
            WHEN r_score >= 4 AND f_score >= 4 AND m_score >= 4 THEN '1. Ядро'
            WHEN r_score >= 4 AND f_score >= 3                  THEN '2. Лояльные'
            WHEN r_score <= 2 AND f_score >= 4                  THEN '3. Уходящие ценные'
            WHEN r_score <= 2 AND f_score <= 2                  THEN '4. Спящие'
            WHEN r_score >= 3 AND f_score <= 2                  THEN '5. Новички и редкие'
            ELSE                                                     '6. Середина'
        END AS segment
    FROM scored
)
SELECT
    segment                                                       AS "Сегмент",
    count(*)                                                      AS "Аккаунтов",
    round(100.0 * count(*) / sum(count(*)) OVER (), 1)            AS "Доля, %",
    round(avg(recency_days))                                      AS "R: дней молчания",
    round(avg(active_days_90), 1)                                 AS "F: активных дней/90",
    round(avg(current_mrr_rub))                                   AS "M: MRR, ₽",
    round(sum(current_mrr_rub))                                   AS "MRR сегмента, ₽",
    round(100.0 * sum(current_mrr_rub) / sum(sum(current_mrr_rub)) OVER (), 1) AS "Доля MRR, %"
FROM segmented
GROUP BY segment
ORDER BY segment;

\echo ''
\echo '=== 6.2 Границы квинтилей ==='
-- Без этой таблицы сегменты — чёрный ящик: непонятно, что значит «редко
-- заходит» в цифрах. Границы заодно показывают, насколько сжато распределение:
-- если первый и пятый квинтиль различаются на пару дней, делить было не на что.

WITH live AS (
    SELECT s.subscription_id, s.user_id, s.current_mrr_rub
    FROM marts.fct_subscription s WHERE s.is_active
),
behaviour AS (
    SELECT
        l.subscription_id,
        l.current_mrr_rub,
        coalesce((marts.snapshot_ts()::date
                  - max(a.activity_date) FILTER (WHERE a.core_actions_cnt > 0)), 999) AS recency_days,
        count(*) FILTER (WHERE a.core_actions_cnt > 0
                           AND a.activity_date > (marts.snapshot_ts() - interval '90 days')::date)
            AS active_days_90
    FROM live l
    LEFT JOIN marts.fct_user_activity_daily a ON a.user_id = l.user_id
    GROUP BY l.subscription_id, l.current_mrr_rub
)
SELECT
    'R: дней с последнего действия' AS "Показатель",
    round(percentile_cont(0.2) WITHIN GROUP (ORDER BY recency_days)::numeric, 1) AS "20-й перцентиль",
    round(percentile_cont(0.5) WITHIN GROUP (ORDER BY recency_days)::numeric, 1) AS "Медиана",
    round(percentile_cont(0.8) WITHIN GROUP (ORDER BY recency_days)::numeric, 1) AS "80-й перцентиль"
FROM behaviour
UNION ALL
SELECT 'F: активных дней за 90',
    round(percentile_cont(0.2) WITHIN GROUP (ORDER BY active_days_90)::numeric, 1),
    round(percentile_cont(0.5) WITHIN GROUP (ORDER BY active_days_90)::numeric, 1),
    round(percentile_cont(0.8) WITHIN GROUP (ORDER BY active_days_90)::numeric, 1)
FROM behaviour
UNION ALL
SELECT 'M: MRR, ₽',
    round(percentile_cont(0.2) WITHIN GROUP (ORDER BY current_mrr_rub)::numeric, 1),
    round(percentile_cont(0.5) WITHIN GROUP (ORDER BY current_mrr_rub)::numeric, 1),
    round(percentile_cont(0.8) WITHIN GROUP (ORDER BY current_mrr_rub)::numeric, 1)
FROM behaviour;

\echo ''
\echo '=== 6.3 Откуда приходят аккаунты из ядра ==='
-- Проверка на практическую пользу: если каналы, дающие ядро, отличаются от
-- каналов, дающих спящих, у маркетинга появляется критерий отбора — не по
-- объёму регистраций, а по доле сильных аккаунтов.

WITH live AS (
    SELECT s.subscription_id, s.user_id, s.current_mrr_rub, u.channel_name
    FROM marts.fct_subscription s JOIN marts.dim_user u USING (user_id)
    WHERE s.is_active
),
behaviour AS (
    SELECT
        l.subscription_id, l.channel_name, l.current_mrr_rub,
        coalesce((marts.snapshot_ts()::date
                  - max(a.activity_date) FILTER (WHERE a.core_actions_cnt > 0)), 999) AS recency_days,
        count(*) FILTER (WHERE a.core_actions_cnt > 0
                           AND a.activity_date > (marts.snapshot_ts() - interval '90 days')::date)
            AS active_days_90
    FROM live l
    LEFT JOIN marts.fct_user_activity_daily a ON a.user_id = l.user_id
    GROUP BY l.subscription_id, l.channel_name, l.current_mrr_rub
),
scored AS (
    SELECT *,
        ntile(5) OVER (ORDER BY recency_days DESC) AS r_score,
        ntile(5) OVER (ORDER BY active_days_90)    AS f_score,
        ntile(5) OVER (ORDER BY current_mrr_rub)   AS m_score
    FROM behaviour
)
SELECT
    channel_name                                                            AS "Канал",
    count(*)                                                                AS "Живых аккаунтов",
    count(*) FILTER (WHERE r_score >= 4 AND f_score >= 4 AND m_score >= 4)  AS "Из них ядро",
    round(100.0 * count(*) FILTER (WHERE r_score >= 4 AND f_score >= 4 AND m_score >= 4)
          / count(*), 1)                                                    AS "Доля ядра, %",
    round(100.0 * count(*) FILTER (WHERE r_score <= 2 AND f_score <= 2)
          / count(*), 1)                                                    AS "Доля спящих, %"
FROM scored
GROUP BY channel_name
ORDER BY "Доля ядра, %" DESC;
