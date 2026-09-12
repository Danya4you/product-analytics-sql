-- =============================================================================
-- 00 — Гигиена данных: что не так с выгрузкой, прежде чем считать метрики
--
-- Этот блок идёт первым не из вежливости. Любая цифра ниже по течению зависит
-- от того, что именно попало в знаменатель, и три вещи из этого файла могут
-- сдвинуть её на проценты:
--
--   • дубли от ретраев трекера — завышают активность;
--   • служебные аккаунты сотрудников — занижают конверсию;
--   • задержка доставки событий — делает свежие когорты хуже, чем они есть.
--
-- Все три чинятся в marts.stg_events и marts.dim_user, а здесь измеряется
-- масштаб: аналитик должен знать, на сколько именно он ошибся бы, если бы
-- взял сырой слой как есть.
-- =============================================================================

\pset border 2

\echo ''
\echo '=== 0.1 Дубли от ретраев трекера ==='
-- Клиент не дождался подтверждения и отправил событие ещё раз. В хранилище
-- две строки: разные event_id, одинаковый event_uid. Сравнение строк целиком
-- такие дубли НЕ ловит — время доставки у копий разное.

WITH per_uid AS (
    SELECT event_uid, count(*) AS copies
    FROM app.events
    GROUP BY event_uid
)
SELECT
    (SELECT count(*) FROM app.events)                                 AS "Строк в сыром логе",
    count(*)                                                          AS "Уникальных событий",
    (SELECT count(*) FROM app.events) - count(*)                      AS "Лишних строк",
    round(100.0 * ((SELECT count(*) FROM app.events) - count(*))
          / (SELECT count(*) FROM app.events), 2)                     AS "Доля мусора, %",
    count(*) FILTER (WHERE copies > 1)                                AS "Событий с повтором",
    max(copies)                                                       AS "Макс. копий одного"
FROM per_uid;

\echo ''
\echo '=== 0.2 Служебные аккаунты сотрудников ==='
-- Единственное, чем они отличаются от клиентов, — канал привлечения. По
-- поведению это обычные пользователи: заходят, создают проекты, что-то делают.
-- И никогда не платят.

WITH raw AS (
    SELECT
        u.user_id,
        (c.channel_code = 'internal') AS is_internal,
        exists (SELECT 1 FROM app.subscriptions s
                 WHERE s.user_id = u.user_id AND s.started_at IS NOT NULL) AS converted
    FROM app.users u
    JOIN app.channels c USING (channel_id)
    WHERE u.signed_up_at < marts.snapshot_ts() - interval '30 days'
)
SELECT
    count(*) FILTER (WHERE is_internal)                               AS "Служебных аккаунтов",
    count(*)                                                          AS "Всего в сыром слое",
    round(100.0 * count(*) FILTER (WHERE converted) / count(*), 2)    AS "Конверсия с ними, %",
    round(100.0 * count(*) FILTER (WHERE converted AND NOT is_internal)
          / count(*) FILTER (WHERE NOT is_internal), 2)               AS "Конверсия без них, %",
    round(100.0 * count(*) FILTER (WHERE converted AND NOT is_internal)
          / count(*) FILTER (WHERE NOT is_internal)
        - 100.0 * count(*) FILTER (WHERE converted) / count(*), 2)    AS "Искажение, п.п."
FROM raw;

\echo ''
\echo '=== 0.3 Задержка доставки событий ==='
-- Разница между «когда произошло» и «когда доехало». Обычно секунды, но хвост
-- уходит на сутки и дальше: мобильный клиент копил события офлайн, очередь
-- вставала, выгрузку перезапускали.

WITH lag AS (
    SELECT
        CASE
            WHEN ingested_at - occurred_at < interval '2 minutes'  THEN '1. до 2 минут'
            WHEN ingested_at - occurred_at < interval '1 hour'     THEN '2. до часа'
            WHEN ingested_at - occurred_at < interval '1 day'      THEN '3. до суток'
            WHEN ingested_at - occurred_at < interval '3 days'     THEN '4. до трёх суток'
            ELSE                                                        '5. больше трёх суток'
        END AS bucket,
        extract(epoch FROM ingested_at - occurred_at) AS seconds
    FROM app.events
)
SELECT
    bucket                                                        AS "Задержка",
    count(*)                                                      AS "Событий",
    round(100.0 * count(*) / sum(count(*)) OVER (), 2)            AS "Доля, %",
    round((max(seconds) / 3600)::numeric, 1)                      AS "Макс. в группе, ч"
FROM lag
GROUP BY bucket
ORDER BY bucket;

\echo ''
\echo '=== 0.4 Пересчёт задним числом: почему вчерашний отчёт не сходится ==='
-- Активация меряется на окне в 7 дней. Но если построить отчёт ровно в момент
-- закрытия окна, часть событий ещё не доехала — и когорта выглядит хуже, чем
-- окажется через неделю. Ниже тот же показатель, посчитанный дважды: «на
-- восьмой день жизни когорты» и «сейчас, когда доехало всё».
--
-- Практический вывод из этой таблицы: у цифры в отчёте должна быть не только
-- дата периода, но и дата расчёта. Иначе два одинаковых отчёта за один месяц
-- расходятся, и никто не может объяснить почему.

WITH asof AS (
    SELECT
        u.cohort_month,
        u.user_id,
        u.is_activated AS final_activated,
        (count(*) FILTER (WHERE e.event_name = 'project_created'
                            AND e.ingested_at <= u.signed_up_at + interval '7 days') > 0
         AND
         count(*) FILTER (WHERE e.event_name = 'task_created'
                            AND e.ingested_at <= u.signed_up_at + interval '7 days') >= 3
        ) AS activated_asof
    FROM marts.dim_user u
    LEFT JOIN marts.stg_events e
           ON e.user_id = u.user_id
          AND e.occurred_at < u.signed_up_at + interval '7 days'
    WHERE u.is_matured
    GROUP BY u.cohort_month, u.user_id, u.is_activated
)
SELECT
    to_char(cohort_month, 'YYYY-MM')                                   AS "Когорта",
    count(*)                                                           AS "Пользователей",
    round(100.0 * count(*) FILTER (WHERE activated_asof) / count(*), 1) AS "Активация в моменте, %",
    round(100.0 * count(*) FILTER (WHERE final_activated) / count(*), 1) AS "Активация сейчас, %",
    count(*) FILTER (WHERE final_activated AND NOT activated_asof)     AS "Досчитались позже"
FROM asof
GROUP BY cohort_month
HAVING count(*) FILTER (WHERE final_activated AND NOT activated_asof) > 0
ORDER BY cohort_month;

\echo ''
\echo '=== 0.5 Итог чистки ==='
-- Сколько строк отсеялось и на сколько это меняет картину.

SELECT
    (SELECT count(*) FROM app.events)                                  AS "Сырой лог",
    (SELECT count(*) FROM marts.stg_events)                            AS "После чистки",
    (SELECT count(*) FROM app.events) - (SELECT count(*) FROM marts.stg_events)
                                                                       AS "Отброшено",
    (SELECT count(*) FROM app.users)                                   AS "Всего аккаунтов",
    (SELECT count(*) FROM marts.dim_user)                              AS "Из них клиентских";
