-- =============================================================================
-- 09 — Освоение функций: что связано с удержанием, а что только кажется
--
-- Стандартный сюжет продуктовой аналитики: «пользователи, подключившие
-- интеграцию, платят в два раза дольше — надо всех заставить подключать
-- интеграцию». Вывод неверный, и запрос ниже показывает, почему.
--
-- Интеграцию подключают те, кто уже решил, что продукт им нужен. Подключение
-- не столько причина удержания, сколько его симптом. Отделить одно от другого
-- по наблюдательным данным нельзя — можно только уменьшить разрыв, сравнивая
-- сопоставимые сегменты. Это и делает раздел 9.2: сравнение внутри групп,
-- одинаковых по активации и размеру компании. Если разрыв после этого
-- схлопывается — эффект был отбором. Если остаётся — есть что тестировать
-- экспериментом, но и только.
-- =============================================================================

\pset border 2

\echo ''
\echo '=== 9.1 Сравнение в лоб (так делать нельзя, но так делают) ==='

WITH adoption AS (
    SELECT
        u.user_id,
        u.is_activated,
        u.company_size,
        (u.invites_first_7d > 0)      AS invited_team,
        (u.integrations_first_7d > 0) AS connected_integration,
        s.is_converted,
        s.is_active,
        s.tenure_months,
        s.revenue_rub
    FROM marts.dim_user u
    LEFT JOIN marts.fct_subscription s ON s.user_id = u.user_id
    WHERE u.is_matured
),
features AS (
    SELECT 'Пригласил коллег'    AS feature, invited_team          AS used, adoption.* FROM adoption
    UNION ALL
    SELECT 'Подключил интеграцию', connected_integration, adoption.* FROM adoption
)
SELECT
    feature                                                        AS "Функция",
    CASE WHEN used THEN 'использовал' ELSE 'нет' END               AS "Группа",
    count(*)                                                       AS "Пользователей",
    round(100.0 * count(*) FILTER (WHERE is_converted) / count(*), 1) AS "Конверсия, %",
    round(avg(tenure_months) FILTER (WHERE is_converted), 1)       AS "Срок жизни, мес",
    round(avg(revenue_rub)   FILTER (WHERE is_converted))          AS "Выручка, ₽"
FROM features
GROUP BY feature, used
ORDER BY feature, used DESC;

\echo ''
\echo '=== 9.2 То же сравнение внутри сопоставимых групп ==='
-- Сегменты фиксируют два главных источника отбора: активацию (насколько
-- человек вообще втянулся) и размер компании (коллег можно пригласить только
-- если они есть). Внутри каждой ячейки сравниваются похожие пользователи.

WITH base AS (
    SELECT
        u.user_id,
        u.is_activated,
        CASE WHEN u.company_size IN ('1','2-10') THEN 'до 10 человек'
             ELSE 'больше 10 человек' END       AS size_group,
        (u.invites_first_7d > 0)                AS invited_team,
        u.is_converted
    FROM marts.dim_user u
    WHERE u.is_matured
)
SELECT
    CASE WHEN is_activated THEN 'активированные' ELSE 'неактивированные' END AS "Активация",
    size_group                                                          AS "Размер компании",
    count(*) FILTER (WHERE invited_team)                                AS "Приглашали",
    count(*) FILTER (WHERE NOT invited_team)                            AS "Нет",
    round(100.0 * count(*) FILTER (WHERE invited_team AND is_converted)
          / nullif(count(*) FILTER (WHERE invited_team), 0), 1)         AS "Конверсия с приглашением, %",
    round(100.0 * count(*) FILTER (WHERE NOT invited_team AND is_converted)
          / nullif(count(*) FILTER (WHERE NOT invited_team), 0), 1)     AS "Конверсия без, %",
    round(100.0 * count(*) FILTER (WHERE invited_team AND is_converted)
          / nullif(count(*) FILTER (WHERE invited_team), 0)
        - 100.0 * count(*) FILTER (WHERE NOT invited_team AND is_converted)
          / nullif(count(*) FILTER (WHERE NOT invited_team), 0), 1)     AS "Разрыв, п.п.",
    round(marts.p_value_two_sided(marts.z_two_proportions(
            count(*) FILTER (WHERE NOT invited_team AND is_converted),
            count(*) FILTER (WHERE NOT invited_team),
            count(*) FILTER (WHERE invited_team AND is_converted),
            count(*) FILTER (WHERE invited_team)))::numeric, 3)         AS "p"
FROM base
GROUP BY is_activated, size_group
ORDER BY is_activated DESC, size_group;

\echo ''
\echo '=== 9.3 Какими функциями пользуются живые подписки ==='
-- Картина использования продукта у платящих: что вообще происходит внутри.
-- Доля аккаунтов, а не число событий — иначе десяток самых активных клиентов
-- перетянет на себя всю статистику.

WITH live_users AS (
    SELECT DISTINCT s.user_id
    FROM marts.fct_subscription s
    WHERE s.is_active
),
-- Сначала сворачиваем до «пользователь × событие», и только потом считаем
-- медиану. Соблазнительный вариант с коррелированным подзапросом «сколько
-- таких событий у этого пользователя» на каждой строке лога превращает запрос
-- в квадратичный: 400 тысяч строк умножаются на поиск по каждой из них.
per_user AS (
    SELECT e.user_id, e.event_name, count(*) AS cnt
    FROM marts.stg_events e
    JOIN live_users l USING (user_id)
    WHERE e.occurred_at > marts.snapshot_ts() - interval '90 days'
      AND e.event_name NOT IN ('signup','email_confirmed','onboarding_completed')
    GROUP BY e.user_id, e.event_name
),
usage AS (
    SELECT
        event_name,
        count(*)                                          AS users,
        sum(cnt)                                          AS events,
        percentile_cont(0.5) WITHIN GROUP (ORDER BY cnt)  AS median_per_user
    FROM per_user
    GROUP BY event_name
)
SELECT
    event_name                                                       AS "Событие",
    users                                                            AS "Аккаунтов",
    round(100.0 * users / (SELECT count(*) FROM live_users), 1)      AS "Охват живых, %",
    events                                                           AS "Событий за 90 дней",
    round(median_per_user::numeric, 1)                               AS "Медиана на аккаунт"
FROM usage
ORDER BY users DESC;
