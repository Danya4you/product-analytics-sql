-- =============================================================================
-- tests/data_quality.sql — проверки целостности данных и витрин
--
-- Запускается последним шагом сборки. Если хоть одна проверка не прошла,
-- скрипт падает с ненулевым кодом возврата — на этом же спотыкается CI.
--
-- Что проверяется и что нет. Ограничения таблиц (внешние ключи, CHECK,
-- уникальность) уже проверены самой базой при загрузке — дублировать их здесь
-- бессмысленно. Ниже то, что база проверить не может: согласованность между
-- таблицами, соответствие данных дате среза и сходимость витрин с сырым слоем.
-- Последнее особенно важно: витрина, которая молча разошлась с источником, —
-- худший вид ошибки, потому что отчёт по ней выглядит правдоподобно.
-- =============================================================================

\set ON_ERROR_STOP on
\pset border 2

DROP TABLE IF EXISTS check_results;

CREATE TEMP TABLE check_results AS
WITH checks AS (

    -- 1. Ничего не произошло после даты среза
    SELECT '01 События не выходят за дату среза' AS check_name,
           (SELECT count(*) FROM app.events WHERE occurred_at >= marts.snapshot_ts()) AS violations,
           'строк событий после среза' AS unit

    UNION ALL
    SELECT '02 Платежи не выходят за дату среза',
           (SELECT count(*) FROM app.payments WHERE paid_at >= marts.snapshot_ts()),
           'платежей после среза'

    UNION ALL
    SELECT '03 Подписки не начинаются после среза',
           (SELECT count(*) FROM app.subscriptions WHERE started_at >= marts.snapshot_ts()),
           'подписок из будущего'

    -- 4. Активность не может предшествовать регистрации
    UNION ALL
    SELECT '04 Активность не раньше регистрации',
           (SELECT count(*)
              FROM app.events e
              JOIN app.users u USING (user_id)
             WHERE e.occurred_at < u.signed_up_at),
           'событий до регистрации'

    -- 5. У каждой оплаченной подписки ровно одно событие convert
    UNION ALL
    SELECT '05 Одно событие convert на подписку',
           (SELECT count(*) FROM (
                SELECT s.subscription_id
                  FROM app.subscriptions s
                  LEFT JOIN app.subscription_events se
                         ON se.subscription_id = s.subscription_id
                        AND se.event_type = 'convert'
                 WHERE s.started_at IS NOT NULL
                 GROUP BY s.subscription_id
                HAVING count(se.event_id) <> 1) x),
           'подписок с неверным числом convert'

    -- 6. У каждой ушедшей подписки ровно одно событие cancel
    UNION ALL
    SELECT '06 Одно событие cancel на ушедшую подписку',
           (SELECT count(*) FROM (
                SELECT s.subscription_id
                  FROM app.subscriptions s
                  LEFT JOIN app.subscription_events se
                         ON se.subscription_id = s.subscription_id
                        AND se.event_type = 'cancel'
                 WHERE s.status = 'churned'
                 GROUP BY s.subscription_id
                HAVING count(se.event_id) <> 1) x),
           'подписок с неверным числом cancel'

    -- 7. У активной подписки не может быть даты окончания
    UNION ALL
    SELECT '07 У активных подписок нет даты окончания',
           (SELECT count(*) FROM app.subscriptions
             WHERE status = 'active' AND ended_at IS NOT NULL),
           'противоречивых подписок'

    -- 8. Платёж не может случиться вне жизни подписки
    UNION ALL
    SELECT '08 Платежи внутри срока жизни подписки',
           (SELECT count(*)
              FROM app.payments p
              JOIN app.subscriptions s USING (subscription_id)
             WHERE p.paid_at < s.started_at - interval '1 day'
                OR (s.ended_at IS NOT NULL AND p.paid_at > s.ended_at + interval '2 days')),
           'платежей вне срока подписки'

    -- 9. Ключевая сверка: водопад MRR сходится с независимым помесячным срезом
    UNION ALL
    SELECT '09 Водопад MRR сходится со срезом',
           (SELECT count(*)
              FROM (SELECT month, sum(sum(mrr_delta_rub)) OVER (ORDER BY month) AS cum
                      FROM marts.fct_mrr_movement GROUP BY month) w
              LEFT JOIN (SELECT month, sum(mrr_rub) AS snap
                           FROM marts.fct_subscription_month GROUP BY month) s USING (month)
             WHERE abs(w.cum - coalesce(s.snap, 0)) > 0.5),
           'месяцев с расхождением больше 50 копеек'

    -- 10. Витрина подписок не потеряла и не размножила строки
    UNION ALL
    SELECT '10 fct_subscription совпадает по объёму с источником',
           (SELECT abs((SELECT count(*) FROM marts.fct_subscription)
                     - (SELECT count(*) FROM app.subscriptions))),
           'строк разницы'

    -- 11. Выручка витрины сходится с платежами
    UNION ALL
    SELECT '11 Выручка витрины сходится с платежами',
           (SELECT CASE WHEN abs(
                    (SELECT coalesce(sum(revenue_rub), 0) FROM marts.fct_subscription)
                  - (SELECT coalesce(sum(amount_rub), 0) FROM app.payments
                      WHERE status IN ('succeeded','refunded'))) > 0.5
                   THEN 1 ELSE 0 END),
           'расхождение суммы выручки'

    -- 12. Активация в витрине пересчитывается напрямую из лога и сверяется.
    --
    --     Первая версия этой проверки спрашивала «нет ли активаций без
    --     проекта» — и не могла провалиться никогда, потому что наличие
    --     проекта входит в само определение активации. Тест, который не в
    --     состоянии упасть, хуже отсутствующего: он создаёт уверенность,
    --     ничего не проверяя. Здесь показатель считается ВТОРОЙ раз, из
    --     сырого лога и другим способом, и сравнивается с витриной.
    UNION ALL
    SELECT '12 Активация сходится с пересчётом из лога',
           (SELECT count(*) FROM (
                SELECT u.user_id,
                       (count(*) FILTER (WHERE e.event_name = 'project_created') > 0
                        AND count(*) FILTER (WHERE e.event_name = 'task_created') >= 3)
                           AS recomputed,
                       max(d.is_activated::int)::boolean AS from_mart
                  FROM app.users u
                  JOIN marts.dim_user d ON d.user_id = u.user_id
                  LEFT JOIN marts.stg_events e
                         ON e.user_id = u.user_id
                        AND e.occurred_at < u.signed_up_at + interval '7 days'
                 WHERE u.email_domain <> 'timeline.ru'
                 GROUP BY u.user_id
            ) x WHERE recomputed IS DISTINCT FROM from_mart),
           'расхождений витрины с логом'

    -- 15. Чистка действительно что-то чистит. Если дубли из сырого слоя
    --     исчезнут (поменялся генератор, сменился источник), дедупликация
    --     останется непроверенной — и сломается молча, когда дубли вернутся.
    UNION ALL
    SELECT '15 В сыром логе есть дубли, на которых проверяется чистка',
           (SELECT CASE WHEN count(*) > 0 THEN 0 ELSE 1 END
              FROM (SELECT event_uid FROM app.events
                     GROUP BY event_uid HAVING count(*) > 1) d),
           'дублей не осталось - дедупликация непроверяема'

    -- 16. После чистки дублей нет ни одного
    UNION ALL
    SELECT '16 В чистом логе нет дублей по event_uid',
           (SELECT count(*) FROM (
                SELECT event_uid FROM marts.stg_events
                 GROUP BY event_uid HAVING count(*) > 1) d),
           'повторов после дедупликации'

    -- 17. Служебные аккаунты не протекли в продуктовые витрины
    UNION ALL
    SELECT '17 Служебных аккаунтов нет в продуктовых витринах',
           (SELECT count(*)
              FROM marts.dim_user d
              JOIN app.users u USING (user_id)
             WHERE u.email_domain = 'timeline.ru'),
           'служебных аккаунтов в dim_user'

    -- 18. Чистка снимает ровно ожидаемое: дубли, боты и служебные аккаунты
    UNION ALL
    SELECT '18 Чистка убрала ровно ожидаемое число строк',
           (SELECT CASE WHEN (SELECT count(*) FROM marts.stg_events)
                           = (SELECT count(DISTINCT e.event_uid)
                                FROM app.events e
                                JOIN marts.stg_identity i ON i.device_id = e.device_id
                                JOIN app.users u ON u.user_id = coalesce(e.user_id, i.user_id)
                               WHERE u.email_domain <> 'timeline.ru')
                        THEN 0 ELSE 1 END),
           'расхождение объёма после чистки'

    -- 19. Склейка не приписала устройство чужому пользователю: у каждого
    --     события с проставленным user_id владелец устройства должен совпадать
    UNION ALL
    SELECT '19 Склейка не противоречит явному user_id',
           (SELECT count(*)
              FROM app.events e
              JOIN marts.stg_identity i ON i.device_id = e.device_id
             WHERE e.user_id IS NOT NULL
               AND e.user_id <> i.user_id
               AND NOT i.device_shared),
           'конфликтов устройства и аккаунта'

    -- 20. Каждый клиентский аккаунт получил решение по атрибуции — пусть даже
    --     «не определён». Пропуск строки означал бы, что пользователь молча
    --     выпал из всех отчётов по каналам.
    UNION ALL
    SELECT '20 Атрибуция посчитана для каждого аккаунта',
           (SELECT count(*) FROM marts.dim_user WHERE channel_code IS NULL),
           'аккаунтов без решения по каналу'

    -- 21. Переименованное событие приведено к общему имени: после окна
    --     сломанного трекинга в чистом логе не должно остаться task_create
    UNION ALL
    SELECT '21 Переименованное событие склеено',
           (SELECT count(*) FROM marts.stg_events WHERE event_name = 'task_create'),
           'событий со старым именем'

    -- 22. Доля неатрибуцированных регистраций в разумных пределах. Не тест
    --     данных, а сигнализация: если атрибуция вдруг развалится и unknown
    --     станет половиной, все отчёты по каналам надо снимать с публикации.
    UNION ALL
    SELECT '22 Доля регистраций без канала ниже 40%',
           (SELECT CASE WHEN avg(CASE WHEN channel_code = 'unknown' THEN 1.0 ELSE 0 END) < 0.40
                        THEN 0 ELSE 1 END FROM marts.dim_user),
           'выход за допустимую долю'

    -- 23. Расходы из кабинетов не приписаны каналам, которых не бывает платными
    UNION ALL
    SELECT '23 Расходы только по платным и партнёрским каналам',
           (SELECT count(*) FROM app.ad_spend s
              JOIN app.channels c USING (channel_id)
             WHERE c.channel_group NOT IN ('paid','referral')),
           'строк расхода по бесплатным каналам'

    -- 13. Распределение по вариантам A/B близко к 50/50 (проверка на SRM)
    --     Допуск 4 процентных пункта: при тысяче наблюдений в группе случайное
    --     отклонение больше этого практически не встречается.
    UNION ALL
    SELECT '13 Баланс групп A/B в пределах допуска',
           (SELECT count(*) FROM (
                SELECT experiment_id
                  FROM app.experiment_assignments
                 GROUP BY experiment_id
                HAVING abs(0.5 - avg(CASE WHEN variant = 'treatment' THEN 1.0 ELSE 0 END)) > 0.04) x),
           'экспериментов с перекосом групп'

    -- 14. Бизнес-правдоподобие: конверсия в оплату в разумном диапазоне.
    --     Не столько тест данных, сколько защита от случайной поломки
    --     генератора — если конверсия вдруг стала 0 % или 90 %, что-то сломано.
    UNION ALL
    SELECT '14 Конверсия в оплату в диапазоне 5-40%',
           (SELECT CASE WHEN avg(CASE WHEN is_converted THEN 1.0 ELSE 0 END)
                        BETWEEN 0.05 AND 0.40 THEN 0 ELSE 1 END
              FROM marts.dim_user WHERE is_matured),
           'выход за диапазон'
)
SELECT * FROM checks;

\echo ''
\echo '=== Проверки качества данных ==='

SELECT
    check_name                                          AS "Проверка",
    violations                                          AS "Нарушений",
    unit                                                AS "Единица",
    CASE WHEN violations = 0 THEN 'OK' ELSE 'ПРОВАЛ' END AS "Итог"
FROM check_results
ORDER BY violations DESC, check_name;

DO $$
DECLARE failed int;
BEGIN
    SELECT count(*) INTO failed FROM check_results WHERE violations <> 0;
    IF failed > 0 THEN
        RAISE EXCEPTION 'Проверок провалено: %. Данные или витрины несогласованы.', failed;
    END IF;
    RAISE NOTICE 'Все проверки пройдены.';
END $$;
