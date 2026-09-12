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

    -- 12. Определение активации согласовано: активированный обязан иметь проект
    UNION ALL
    SELECT '12 Активация подразумевает созданный проект',
           (SELECT count(*) FROM marts.dim_user
             WHERE is_activated AND first_project_at IS NULL),
           'активаций без проекта'

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
