-- =============================================================================
-- 04 — Юнит-экономика каналов привлечения
--
-- Вопрос: какие каналы окупаются, а какие приносят трафик, который никогда не
-- вернёт вложенного.
--
-- Допущения, без которых расчёт не имеет смысла. Они вынесены наверх, чтобы их
-- можно было оспорить, а не искать по тексту запроса:
--
--   1. Валовая маржа 80 %. Типично для SaaS: из подписки вычитаются хостинг,
--      поддержка и эквайринг. Число взято как отраслевой ориентир и должно
--      быть заменено на фактическое, как только появится отчёт о затратах.
--   2. CAC — плановая ставка канала на одну РЕГИСТРАЦИЮ из app.channels, а не
--      фактический расход за период. Реальный CAC считается делением бюджета на
--      число регистраций и по месяцам гуляет; здесь он зафиксирован, иначе
--      каналы нельзя сравнить между собой.
--   3. LTV считается по модели постоянного оттока: LTV = ARPU × маржа / отток.
--      Модель завышает LTV, если отток падает с возрастом подписки (а он
--      падает — см. запрос 05). Поэтому рядом стоит фактически собранная
--      выручка на платящего: это оценка снизу, между ними и лежит истина.
-- =============================================================================

\pset border 2

\echo ''
\echo '=== 4.1 Экономика по каналам ==='

WITH channel_users AS (
    SELECT
        channel_code,
        channel_name,
        channel_group,
        max(cac_rub)                                   AS cac_signup,
        count(*)                                       AS signups,
        count(*) FILTER (WHERE is_converted)           AS paying
    FROM marts.dim_user
    WHERE is_matured
    GROUP BY channel_code, channel_name, channel_group
),
channel_subs AS (
    SELECT
        u.channel_code,
        avg(s.first_mrr_rub)                                        AS arpu,
        sum(s.revenue_rub)                                          AS revenue,
        count(*)                                                    AS subs,
        count(*) FILTER (WHERE NOT s.is_active)                     AS churned,
        sum(s.tenure_months)                                        AS months_at_risk
    FROM marts.fct_subscription s
    JOIN marts.dim_user u USING (user_id)
    WHERE s.is_converted AND u.is_matured
    GROUP BY u.channel_code
),
economics AS (
    SELECT
        cu.*,
        cs.arpu,
        cs.revenue,
        cs.subs,
        -- месячный отток как доля ушедших на один месяц под риском
        cs.churned / nullif(cs.months_at_risk, 0)               AS churn_monthly,
        0.80                                                     AS margin,
        cu.cac_signup * cu.signups / nullif(cu.paying, 0)        AS cac_paying
    FROM channel_users cu
    JOIN channel_subs cs USING (channel_code)
)
SELECT
    channel_name                                              AS "Канал",
    signups                                                   AS "Регистраций",
    paying                                                    AS "Платящих",
    round(100.0 * paying / signups, 1)                        AS "Конверсия, %",
    round(cac_paying)                                         AS "CAC платящего, ₽",
    round(arpu)                                               AS "ARPU, ₽/мес",
    round(100 * churn_monthly, 1)                             AS "Отток, %/мес",
    round(arpu * margin / nullif(churn_monthly, 0))           AS "LTV модельный, ₽",
    round(revenue / nullif(paying, 0))                        AS "Собрано факт., ₽",
    round(arpu * margin / nullif(churn_monthly, 0) / nullif(cac_paying, 0), 2) AS "LTV/CAC",
    round(cac_paying / nullif(arpu * margin, 0), 1)           AS "Окупаемость, мес"
FROM economics
ORDER BY "LTV/CAC" DESC NULLS LAST;

\echo ''
\echo '=== 4.2 Где заканчиваются деньги: платные каналы против бесплатных ==='
-- Сводка по группам. Для платных каналов дополнительно считается, сколько
-- денег ушло в привлечение тех, кто так и не заплатил.

WITH per_group AS (
    SELECT
        u.channel_group,
        count(*)                                          AS signups,
        count(*) FILTER (WHERE u.is_converted)            AS paying,
        sum(u.cac_rub)                                    AS spend_total,
        sum(u.cac_rub) FILTER (WHERE NOT u.is_converted)  AS spend_wasted,
        coalesce(sum(s.revenue_rub), 0)                   AS revenue
    FROM marts.dim_user u
    LEFT JOIN marts.fct_subscription s ON s.user_id = u.user_id AND s.is_converted
    WHERE u.is_matured
    GROUP BY u.channel_group
)
SELECT
    channel_group                                        AS "Тип канала",
    signups                                              AS "Регистраций",
    paying                                               AS "Платящих",
    round(spend_total)                                   AS "Затраты, ₽",
    round(spend_wasted)                                  AS "Из них впустую, ₽",
    round(100.0 * spend_wasted / nullif(spend_total, 0), 1) AS "Доля впустую, %",
    round(revenue)                                       AS "Собрано, ₽",
    round(revenue * 0.80 - spend_total)                  AS "Валовая прибыль, ₽"
FROM per_group
ORDER BY "Валовая прибыль, ₽" DESC;

\echo ''
\echo '=== 4.3 Окупаемость по месяцам: когда канал выходит в плюс ==='
-- Накопленная валовая прибыль на одного привлечённого пользователя по месяцам
-- жизни. Месяц, в котором значение переходит через ноль, и есть срок
-- окупаемости — уже без модельных допущений, на фактических платежах.

WITH cohort AS (
    SELECT u.user_id, u.channel_name, u.cac_rub
    FROM marts.dim_user u
    WHERE u.is_matured AND u.observed_days >= 180      -- дожили минимум до шестого месяца
),
cash AS (
    SELECT
        c.channel_name,
        least(6, floor(extract(epoch FROM p.paid_at - u.signed_up_at) / 2629746))::int AS month_index,
        sum(p.amount_rub) AS collected
    FROM cohort c
    JOIN marts.dim_user u USING (user_id)
    JOIN marts.fct_subscription s ON s.user_id = c.user_id
    JOIN app.payments p ON p.subscription_id = s.subscription_id
                       AND p.status IN ('succeeded','refunded')
    GROUP BY c.channel_name, 2
),
sizes AS (
    SELECT channel_name, count(*) AS users, sum(cac_rub) AS spend
    FROM cohort GROUP BY channel_name
)
SELECT
    s.channel_name                                                        AS "Канал",
    s.users                                                               AS "Когорта",
    round(-s.spend / s.users)                                             AS "М0",
    round((sum(c.collected) FILTER (WHERE c.month_index <= 1) * 0.80 - s.spend) / s.users) AS "М1",
    round((sum(c.collected) FILTER (WHERE c.month_index <= 3) * 0.80 - s.spend) / s.users) AS "М3",
    round((sum(c.collected) FILTER (WHERE c.month_index <= 6) * 0.80 - s.spend) / s.users) AS "М6"
FROM sizes s
LEFT JOIN cash c USING (channel_name)
GROUP BY s.channel_name, s.users, s.spend
ORDER BY "М6" DESC;
