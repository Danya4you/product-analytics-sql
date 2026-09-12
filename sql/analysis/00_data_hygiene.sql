-- =============================================================================
-- 00 — Гигиена данных: что не так с выгрузкой, прежде чем считать метрики
--
-- Этот блок идёт первым не из вежливости. Любая цифра ниже по течению зависит
-- от того, что попало в знаменатель, и шесть вещей из этого файла могут
-- сдвинуть её на проценты, а одна — на десятки процентов.
--
-- Все дефекты разбираются в marts.stg_identity, marts.stg_events и
-- marts.stg_attribution. Здесь измеряется масштаб: аналитик обязан знать, на
-- сколько именно он ошибся бы, взяв сырой слой как есть.
-- =============================================================================

\pset border 2

\echo ''
\echo '=== 0.1 Дубли от ретраев трекера ==='
-- Клиент не дождался подтверждения и отправил событие ещё раз. Две строки:
-- разные event_id, одинаковый event_uid. Сравнение строк целиком такие дубли
-- НЕ ловит — время доставки у копий разное.

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
\echo '=== 0.2 Склейка: кому принадлежат анонимные события ==='
-- До входа в аккаунт продукт знает только устройство. Такие события надо
-- связать с человеком, иначе весь долог до регистрации — просмотр тарифов,
-- чтение блога — выпадает из его истории.
--
-- Устройства, на которых никто никогда не входил, связать не с кем. Это боты,
-- поисковые роботы и случайные посетители; они отсекаются не эвристикой
-- «слишком часто ходит», а отсутствием владельца.

SELECT
    (SELECT count(*) FROM app.events)                                   AS "Всего событий",
    (SELECT count(*) FROM app.events WHERE user_id IS NULL)             AS "Без пользователя",
    (SELECT count(*) FROM marts.stg_events WHERE stitched)              AS "Склеено по устройству",
    (SELECT count(DISTINCT device_id) FROM app.events)                  AS "Устройств всего",
    (SELECT count(*) FROM marts.stg_identity)                           AS "Из них с владельцем",
    (SELECT count(*) FROM app.events e
      WHERE NOT EXISTS (SELECT 1 FROM marts.stg_identity i
                         WHERE i.device_id = e.device_id))              AS "Событий отброшено (боты)";

\echo ''
\echo '=== 0.3 Служебные аккаунты сотрудников ==='
-- Единственное, чем они отличаются от клиентов, — домен почты. По поведению
-- обычные пользователи: заходят, создают проекты. И никогда не платят.

WITH raw AS (
    SELECT
        u.user_id,
        (u.email_domain = 'timeline.ru') AS is_internal,
        exists (SELECT 1 FROM app.subscriptions s
                 WHERE s.user_id = u.user_id AND s.started_at IS NOT NULL) AS converted
    FROM app.users u
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
\echo '=== 0.4 Атрибуция: у скольких регистраций вообще есть канал ==='
-- Самый крупный пробел в данных. Канала в базе нет — он восстанавливается из
-- касаний, и у части пользователей касаний не сохранилось: заблокированы куки,
-- потеряны метки при редиректе, переход из мессенджера.
--
-- Это не чинится запросом. Неатрибуцированные регистрации нельзя ни выбросить
-- (тогда доли каналов посчитаны не от всех), ни приписать к «прямым» (тогда
-- прямой канал станет крупнейшим на пустом месте).

SELECT
    attribution_quality                                        AS "Качество атрибуции",
    count(*)                                                   AS "Регистраций",
    round(100.0 * count(*) / sum(count(*)) OVER (), 1)         AS "Доля, %",
    round(avg(touches_cnt), 1)                                 AS "Касаний в среднем",
    round(100.0 * count(*) FILTER (WHERE is_converted) / count(*), 1) AS "Конверсия, %"
FROM marts.dim_user
GROUP BY attribution_quality
ORDER BY count(*) DESC;

\echo ''
\echo '=== 0.5 Сломанный трекинг: событие, которое переименовали ==='
-- С 15 января по 5 февраля 2026 года мобильный клиент слал task_create вместо
-- task_created. Продукт не менялся — менялся релиз приложения.
--
-- Слева то, что видно в сыром логе: в январе создание задач с мобильных
-- проседает. Справа — после склейки имён в staging. Разница и есть цена
-- невнимательности: метрика упала бы на ровном месте, и месяц ушёл бы на
-- поиск продуктовой причины, которой нет.

WITH months AS (
    SELECT generate_series(date '2025-11-01', date '2026-04-01', interval '1 month')::date AS month
)
SELECT
    to_char(m.month, 'YYYY-MM')                                         AS "Месяц",
    count(*) FILTER (WHERE e.event_name = 'task_created')               AS "Сырой лог: task_created",
    count(*) FILTER (WHERE e.event_name = 'task_create')                AS "Сырой лог: task_create",
    (SELECT count(*) FROM marts.stg_events s
      WHERE s.event_name = 'task_created'
        AND s.occurred_at >= m.month
        AND s.occurred_at < m.month + interval '1 month')               AS "После склейки имён"
FROM months m
LEFT JOIN app.events e
       ON e.occurred_at >= m.month
      AND e.occurred_at < m.month + interval '1 month'
GROUP BY m.month
ORDER BY m.month;

\echo ''
\echo '=== 0.6 Задержка доставки событий ==='
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
\echo '=== 0.7 Пересчёт задним числом: почему вчерашний отчёт не сходится ==='
-- Активация меряется на окне в 7 дней. Если построить отчёт ровно в момент
-- закрытия окна, часть событий ещё не доехала — и когорта выглядит хуже, чем
-- окажется через неделю.
--
-- Практический вывод: у цифры в отчёте должна быть не только дата периода, но
-- и дата расчёта. Иначе два одинаковых отчёта за один месяц расходятся, и
-- никто не может объяснить почему.

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
\echo '=== 0.8 Итог чистки ==='

SELECT
    (SELECT count(*) FROM app.events)                                  AS "Сырой лог",
    (SELECT count(*) FROM marts.stg_events)                            AS "После чистки",
    (SELECT count(*) FROM app.events) - (SELECT count(*) FROM marts.stg_events)
                                                                       AS "Отброшено",
    (SELECT count(*) FROM app.users)                                   AS "Всего аккаунтов",
    (SELECT count(*) FROM marts.dim_user)                              AS "Из них клиентских",
    (SELECT count(*) FROM marts.dim_user WHERE channel_code = 'unknown')
                                                                       AS "Без канала";
