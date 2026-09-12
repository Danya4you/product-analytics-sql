-- =============================================================================
-- 03 — Водопад MRR: откуда берутся и куда деваются деньги
--
-- Помесячная раскладка изменения MRR на пять составляющих: новые подписки,
-- вернувшиеся клиенты, апгрейды, даунгрейды и отток. Сумма составляющих равна
-- изменению MRR за месяц — это свойство и проверяется в конце файла.
--
-- Зачем так, а не «выручка по месяцам»: выручка растёт и когда продукт хорош,
-- и когда просто залили денег в рекламу. Водопад разделяет эти случаи.
-- =============================================================================

\pset border 2

\echo ''
\echo '=== 3.1 Помесячный водопад MRR ==='

WITH movements AS (
    SELECT
        month,
        sum(mrr_delta_rub) FILTER (WHERE movement_type = 'new')          AS new_mrr,
        sum(mrr_delta_rub) FILTER (WHERE movement_type = 'reactivation') AS reactivation_mrr,
        sum(mrr_delta_rub) FILTER (WHERE movement_type = 'expansion')    AS expansion_mrr,
        sum(mrr_delta_rub) FILTER (WHERE movement_type = 'contraction')  AS contraction_mrr,
        sum(mrr_delta_rub) FILTER (WHERE movement_type = 'churn')        AS churn_mrr,
        sum(mrr_delta_rub)                                               AS net_mrr
    FROM marts.fct_mrr_movement
    GROUP BY month
)
SELECT
    to_char(month, 'YYYY-MM')                                     AS "Месяц",
    round(coalesce(new_mrr, 0))                                   AS "Новые",
    round(coalesce(reactivation_mrr, 0))                          AS "Вернулись",
    round(coalesce(expansion_mrr, 0))                             AS "Апгрейды",
    round(coalesce(contraction_mrr, 0))                           AS "Даунгрейды",
    round(coalesce(churn_mrr, 0))                                 AS "Отток",
    round(net_mrr)                                                AS "Итого",
    round(sum(net_mrr) OVER (ORDER BY month))                      AS "MRR на конец",
    round(100.0 * net_mrr / nullif(sum(net_mrr) OVER (ORDER BY month
                                   ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0), 1)
                                                                  AS "Рост, %"
FROM movements
ORDER BY month;

\echo ''
\echo '=== 3.2 Quick Ratio: во сколько раз приход перекрывает потери ==='
-- Quick Ratio = (новые + вернувшиеся + апгрейды) / (даунгрейды + отток).
-- Ориентир для SaaS: ниже 1 — компания сжимается, 1–2 — растёт с трудом,
-- выше 4 — здоровый рост. Считается по кварталам: на месячных данных
-- показатель слишком шумный, чтобы делать по нему выводы.

WITH quarterly AS (
    SELECT
        date_trunc('quarter', month)::date AS quarter,
        sum(mrr_delta_rub) FILTER (WHERE movement_type IN ('new','reactivation','expansion')) AS gained,
        -abs(sum(mrr_delta_rub) FILTER (WHERE movement_type IN ('contraction','churn')))      AS lost
    FROM marts.fct_mrr_movement
    GROUP BY 1
)
SELECT
    to_char(quarter, 'YYYY "к"Q')            AS "Квартал",
    round(gained)                            AS "Приход, ₽",
    round(lost)                              AS "Потери, ₽",
    round(gained / nullif(abs(lost), 0), 2)  AS "Quick Ratio",
    CASE
        WHEN gained / nullif(abs(lost), 0) >= 4 THEN 'здоровый рост'
        WHEN gained / nullif(abs(lost), 0) >= 2 THEN 'рост'
        WHEN gained / nullif(abs(lost), 0) >= 1 THEN 'на грани'
        ELSE 'сжатие'
    END                                      AS "Оценка"
FROM quarterly
ORDER BY quarter;

\echo ''
\echo '=== 3.3 Из чего складывается отток MRR ==='
-- Причину отмены знают НЕ ПРО ВСЕХ, и это главное, что надо сказать про эту
-- таблицу. Пассивный отток причины не имеет вовсе: списание не прошло, клиент
-- ничего не отменял и формы опроса не видел. Из оставшихся форму заполняет
-- меньше половины.
--
-- Поэтому разбор идёт в два шага. Сначала природа оттока — она известна про
-- каждую подписку, потому что выводится из платежей. И только потом причины,
-- с явным указанием, от какой доли считается процент.

SELECT
    CASE s.churn_type
        WHEN 'passive'          THEN 'Не прошло списание'
        WHEN 'voluntary_stated' THEN 'Отменил, назвал причину'
        WHEN 'voluntary_silent' THEN 'Отменил, причину не назвал'
    END                                                            AS "Природа оттока",
    count(*)                                                       AS "Подписок",
    round(100.0 * count(*) / sum(count(*)) OVER (), 1)             AS "Доля, %",
    round(sum(abs(m.mrr_delta_rub)))                               AS "Потерянный MRR, ₽",
    round(avg(s.tenure_months), 1)                                 AS "Прожили, мес",
    round(avg(s.revenue_rub))                                      AS "Успели заплатить, ₽"
FROM marts.fct_mrr_movement m
JOIN marts.fct_subscription s USING (subscription_id)
WHERE m.movement_type = 'churn'
GROUP BY s.churn_type
ORDER BY sum(abs(m.mrr_delta_rub)) DESC;

\echo ''
\echo '=== 3.3b Названные причины — от тех, кто ответил ==='
-- Знаменатель здесь — только ответившие на опрос, и переносить эти доли на
-- весь отток нельзя. Отвечают не случайные люди: тот, кто ушёл из-за цены,
-- охотнее объясняется, чем тот, кому продукт просто надоел. Смещение выборки
-- измерить нечем, поэтому таблица читается как «о чём говорят ушедшие», а не
-- «почему уходят».

WITH stated AS (
    SELECT s.cancel_reason, s.tenure_months, s.revenue_rub, m.mrr_delta_rub
    FROM marts.fct_mrr_movement m
    JOIN marts.fct_subscription s USING (subscription_id)
    WHERE m.movement_type = 'churn' AND s.cancel_reason IS NOT NULL
)
SELECT
    cancel_reason                                            AS "Причина",
    count(*)                                                 AS "Подписок",
    round(100.0 * count(*) / sum(count(*)) OVER (), 1)       AS "Доля ответивших, %",
    round(100.0 * count(*) / (SELECT count(*) FROM marts.fct_subscription
                               WHERE status = 'churned'), 1) AS "Доля всего оттока, %",
    round(sum(abs(mrr_delta_rub)))                           AS "Потерянный MRR, ₽",
    round(avg(tenure_months), 1)                             AS "Прожили, мес"
FROM stated
GROUP BY cancel_reason
ORDER BY count(*) DESC;

\echo ''
\echo '=== 3.4 Сверка: водопад против независимого среза ==='
-- Накопленная сумма движений обязана совпасть с суммой MRR живых подписок на
-- конец месяца, посчитанной по другой витрине и другим способом. Расхождение
-- означает, что в логе событий потерялось движение. Столбец «Расхождение»
-- должен быть нулевым во всех строках.

WITH from_movements AS (
    SELECT
        month,
        sum(sum(mrr_delta_rub)) OVER (ORDER BY month) AS mrr_cumulative
    FROM marts.fct_mrr_movement
    GROUP BY month
),
from_snapshot AS (
    SELECT month, sum(mrr_rub) AS mrr_snapshot
    FROM marts.fct_subscription_month
    GROUP BY month
)
SELECT
    to_char(m.month, 'YYYY-MM')                           AS "Месяц",
    round(m.mrr_cumulative)                               AS "Водопад, ₽",
    round(coalesce(s.mrr_snapshot, 0))                    AS "Срез, ₽",
    round(m.mrr_cumulative - coalesce(s.mrr_snapshot, 0)) AS "Расхождение"
FROM from_movements m
LEFT JOIN from_snapshot s USING (month)
ORDER BY m.month;
