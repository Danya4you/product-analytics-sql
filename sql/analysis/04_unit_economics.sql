-- =============================================================================
-- 04 — Юнит-экономика каналов привлечения
--
-- Вопрос: какие каналы окупаются, а какие приносят трафик, который никогда не
-- вернёт вложенного.
--
-- Этот блок сложнее остальных не из-за SQL, а из-за данных. Три вещи, которых
-- нет ни в одной таблице и которые приходится решать аналитику:
--
--   1. КАНАЛА У ПОЛЬЗОВАТЕЛЯ НЕТ. Он восстановлен из касаний по модели
--      (marts.stg_attribution), и другая модель даст другой ответ. Раздел 4.1
--      показывает, насколько сильно.
--
--   2. ЧАСТЬ РЕГИСТРАЦИЙ НЕ АТРИБУЦИРОВАНА ВООБЩЕ. Их нельзя ни выбросить
--      (тогда CAC завышен), ни разбросать по каналам (тогда он занижен).
--      Раздел 4.3 считает оба варианта и показывает вилку.
--
--   3. РАСХОД И РЕГИСТРАЦИИ ЖИВУТ В РАЗНОЙ ГРАНУЛЯРНОСТИ. В app.ad_spend —
--      день, канал, кампания; в app.users — человек. Связать их можно только
--      агрегатами по периоду и каналу, и это единственный доступный способ.
--
-- Допущения, вынесенные наверх, чтобы их можно было оспорить:
--   • валовая маржа 80 % — отраслевой ориентир для SaaS;
--   • LTV считается по модели постоянного оттока и завышена (см. docs/metrics.md);
--   • органические каналы бесплатными не являются, но их затраты в данных
--     отсутствуют, поэтому LTV/CAC для них не считается вовсе — лучше пусто,
--     чем деление на ноль, выглядящее как бесконечная окупаемость.
-- =============================================================================

\pset border 2

\echo ''
\echo '=== 4.1 Сколько регистраций вообще удалось атрибуцировать ==='
-- Первый вопрос к любой таблице по каналам: какая часть данных в неё не попала.
-- Если четверть регистраций не атрибуцирована, любые доли каналов считаются
-- от трёх четвертей — и это надо говорить вслух, а не прятать в сноску.

SELECT
    attribution_quality                                       AS "Качество атрибуции",
    count(*)                                                  AS "Регистраций",
    round(100.0 * count(*) / sum(count(*)) OVER (), 1)        AS "Доля, %",
    round(100.0 * count(*) FILTER (WHERE is_converted) / count(*), 1) AS "Конверсия, %"
FROM marts.dim_user
WHERE is_matured
GROUP BY attribution_quality
ORDER BY count(*) DESC;

\echo ''
\echo '=== 4.2 Две модели атрибуции — два ответа ==='
-- Один и тот же пользователь при last non-direct click и при first touch
-- относится к разным каналам. Столбец «Расхождение» показывает, на сколько
-- регистраций модель меняет размер канала. Если он велик, вывод «канал X
-- лучший» держится на выборе модели, а не на данных.

WITH base AS (
    SELECT channel_code, channel_code_first_touch
    FROM marts.dim_user
    WHERE is_matured
),
last_click AS (
    SELECT channel_code AS ch, count(*) AS n FROM base GROUP BY 1
),
first_touch AS (
    SELECT channel_code_first_touch AS ch, count(*) AS n FROM base GROUP BY 1
)
SELECT
    coalesce(l.ch, f.ch)                                       AS "Канал",
    coalesce(l.n, 0)                                           AS "Last non-direct",
    coalesce(f.n, 0)                                           AS "First touch",
    coalesce(f.n, 0) - coalesce(l.n, 0)                        AS "Расхождение",
    round(100.0 * (coalesce(f.n, 0) - coalesce(l.n, 0))
          / nullif(coalesce(l.n, 0), 0), 1)                    AS "Расхождение, %"
FROM last_click l
FULL JOIN first_touch f ON f.ch = l.ch
ORDER BY coalesce(l.n, 0) DESC;

\echo ''
\echo '=== 4.3 Стоимость привлечения: расход из кабинетов против регистраций ==='
-- CAC собирается из двух источников с разной гранулярностью: суточные расходы
-- по кампаниям и поштучные регистрации. Общего ключа нет, связываем по месяцу
-- и каналу.
--
-- Колонок с CAC две намеренно. «По атрибуции» делит расход на те регистрации,
-- которые модель сумела опознать, — это оценка СВЕРХУ, потому что часть
-- пришедших из рекламы осела в «не определён». «С разносом» дополнительно
-- приписывает каналу его долю неатрибуцированных регистраций — оценка СНИЗУ.
-- Истина между ними, и решать по одной из цифр, не видя второй, нельзя.

WITH spend AS (
    SELECT
        c.channel_code,
        sum(s.spend_rub) AS spend_rub,
        sum(s.clicks)    AS clicks
    FROM app.ad_spend s
    JOIN app.channels c USING (channel_id)
    GROUP BY c.channel_code
),
signups AS (
    SELECT channel_code, count(*) AS signups,
           count(*) FILTER (WHERE is_converted) AS paying
    FROM marts.dim_user WHERE is_matured
    GROUP BY channel_code
),
unknown_pool AS (
    SELECT count(*) AS unknown_signups
    FROM marts.dim_user
    WHERE is_matured AND channel_code = 'unknown'
),
known_total AS (
    SELECT sum(signups) AS known_signups
    FROM signups WHERE channel_code NOT IN ('unknown')
)
SELECT
    sp.channel_code                                                AS "Канал",
    round(sp.spend_rub)                                            AS "Расход, ₽",
    sp.clicks                                                      AS "Кликов",
    si.signups                                                     AS "Регистраций",
    round(100.0 * si.signups / sp.clicks, 2)                       AS "Клик→рег., %",
    round(sp.spend_rub / nullif(si.signups, 0))                    AS "CAC по атрибуции, ₽",
    round(sp.spend_rub / nullif(si.signups
          + up.unknown_signups * si.signups::numeric / kt.known_signups, 0))
                                                                   AS "CAC с разносом, ₽",
    round(sp.spend_rub / nullif(si.paying, 0))                     AS "CAC платящего, ₽"
FROM spend sp
JOIN signups si USING (channel_code)
CROSS JOIN unknown_pool up
CROSS JOIN known_total  kt
ORDER BY sp.spend_rub DESC;

\echo ''
\echo '=== 4.4 Окупаемость платных каналов ==='
-- LTV/CAC считается только там, где расход известен. Для органики, рефералки и
-- неатрибуцированных регистраций колонка пуста — это честнее, чем поставить
-- ноль в знаменатель и получить впечатляющую бесконечность.

WITH spend AS (
    SELECT c.channel_code, sum(s.spend_rub) AS spend_rub
    FROM app.ad_spend s JOIN app.channels c USING (channel_id)
    GROUP BY c.channel_code
),
channel_users AS (
    SELECT channel_code, channel_name, count(*) AS signups,
           count(*) FILTER (WHERE is_converted) AS paying
    FROM marts.dim_user WHERE is_matured
    GROUP BY channel_code, channel_name
),
channel_subs AS (
    SELECT
        u.channel_code,
        avg(s.first_mrr_rub)                                AS arpu,
        sum(s.revenue_rub)                                  AS revenue,
        count(*) FILTER (WHERE NOT s.is_active)
            / nullif(sum(s.tenure_months), 0)               AS churn_monthly
    FROM marts.fct_subscription s
    JOIN marts.dim_user u USING (user_id)
    WHERE s.is_converted AND u.is_matured
    GROUP BY u.channel_code
)
SELECT
    cu.channel_name                                              AS "Канал",
    cu.signups                                                   AS "Регистраций",
    round(100.0 * cu.paying / cu.signups, 1)                     AS "Конверсия, %",
    round(cs.arpu)                                               AS "ARPU, ₽/мес",
    round(100 * cs.churn_monthly, 1)                             AS "Отток, %/мес",
    round(sp.spend_rub / nullif(cu.paying, 0))                   AS "CAC платящего, ₽",
    round(cs.arpu * 0.80 / nullif(cs.churn_monthly, 0))          AS "LTV модельный, ₽",
    round(cs.revenue / nullif(cu.paying, 0))                     AS "Собрано факт., ₽",
    round(cs.arpu * 0.80 / nullif(cs.churn_monthly, 0)
          / nullif(sp.spend_rub / nullif(cu.paying, 0), 0), 2)   AS "LTV/CAC",
    round(sp.spend_rub / nullif(cu.paying, 0)
          / nullif(cs.arpu * 0.80, 0), 1)                        AS "Окупаемость, мес"
FROM channel_users cu
JOIN channel_subs  cs USING (channel_code)
LEFT JOIN spend    sp USING (channel_code)
ORDER BY "LTV/CAC" DESC NULLS LAST;

\echo ''
\echo '=== 4.5 Сколько денег ушло впустую ==='
-- Весь рекламный расход против того, что собрано с привлечённых им платящих.
-- Неатрибуцированные регистрации показаны отдельной строкой: приписывать их
-- рекламе нельзя, игнорировать — тоже.

WITH spend AS (SELECT sum(spend_rub) AS total FROM app.ad_spend),
paid_users AS (
    SELECT
        count(*)                                             AS signups,
        count(*) FILTER (WHERE u.is_converted)               AS paying,
        coalesce(sum(s.revenue_rub), 0)                      AS revenue
    FROM marts.dim_user u
    LEFT JOIN marts.fct_subscription s ON s.user_id = u.user_id AND s.is_converted
    WHERE u.is_matured AND u.channel_group = 'paid'
),
unattributed AS (
    SELECT count(*) AS signups,
           count(*) FILTER (WHERE is_converted) AS paying
    FROM marts.dim_user WHERE is_matured AND channel_code = 'unknown'
)
SELECT
    round(sp.total)                                          AS "Расход всего, ₽",
    pu.signups                                               AS "Регистраций из рекламы",
    pu.paying                                                AS "Из них платящих",
    round(100.0 * (pu.signups - pu.paying) / pu.signups, 1)  AS "Не заплатили, %",
    round(pu.revenue)                                        AS "Собрано с них, ₽",
    round(pu.revenue * 0.80 - sp.total)                      AS "Валовая прибыль, ₽",
    un.signups                                               AS "Регистраций без канала",
    un.paying                                                AS "Из них платящих"
FROM spend sp CROSS JOIN paid_users pu CROSS JOIN unattributed un;

\echo ''
\echo '=== 4.6 Расход по месяцам: когда платили, а регистраций не было ==='
-- Проверка стыковки двух источников. Месяцы, где расход есть, а регистраций из
-- канала нет, — либо провал атрибуции, либо реклама действительно не сработала.
-- Различить нельзя, но знать надо: именно на этих месяцах CAC улетает вверх.

WITH spend AS (
    SELECT date_trunc('month', s.spend_date)::date AS month,
           c.channel_code, sum(s.spend_rub) AS spend_rub
    FROM app.ad_spend s JOIN app.channels c USING (channel_id)
    GROUP BY 1, 2
),
signups AS (
    SELECT cohort_month AS month, channel_code, count(*) AS signups
    FROM marts.dim_user
    GROUP BY 1, 2
)
SELECT
    sp.channel_code                                       AS "Канал",
    count(*)                                              AS "Месяцев с расходом",
    count(*) FILTER (WHERE coalesce(si.signups, 0) = 0)   AS "Из них без регистраций",
    round(min(sp.spend_rub / nullif(si.signups, 0)))      AS "Лучший CAC, ₽",
    round(max(sp.spend_rub / nullif(si.signups, 0)))      AS "Худший CAC, ₽",
    round(avg(sp.spend_rub / nullif(si.signups, 0)))      AS "Средний CAC, ₽"
FROM spend sp
LEFT JOIN signups si USING (month, channel_code)
GROUP BY sp.channel_code
ORDER BY sp.channel_code;
