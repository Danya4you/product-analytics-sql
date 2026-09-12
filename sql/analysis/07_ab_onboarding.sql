-- =============================================================================
-- 07 — A/B-тест «Чек-лист онбординга v2»
--
-- Гипотеза: пошаговый чек-лист вместо приветственного видео доведёт больше
-- новых пользователей до активации.
--
-- Порядок разбора — тот, в котором его надо делать, а не тот, в котором
-- хочется:
--   1. Проверить, что распределение по группам не сломано (SRM). Пока это не
--      сделано, остальные числа смотреть бессмысленно.
--   2. Оценить ЗАРАНЕЕ выбранную основную метрику.
--   3. Посмотреть вторичные — но помнить, что тест не был на них рассчитан.
--   4. Разрезы по сегментам — в последнюю очередь и только как повод для
--      следующей гипотезы, а не как вывод.
-- =============================================================================

\pset border 2
\set exp_code 'onboarding_checklist_v2'

\echo ''
\echo '=== 7.1 Паспорт эксперимента ==='

SELECT
    experiment_name                                   AS "Эксперимент",
    to_char(started_at, 'DD.MM.YYYY')                 AS "Начало",
    to_char(ended_at,   'DD.MM.YYYY')                 AS "Конец",
    primary_metric                                    AS "Основная метрика",
    hypothesis                                        AS "Гипотеза"
FROM app.experiments
WHERE experiment_code = :'exp_code';

\echo ''
\echo '=== 7.2 Проверка расщепления трафика (SRM) ==='
-- Sample Ratio Mismatch: если фактическое соотношение групп заметно отличается
-- от запланированного 50/50, значит часть пользователей распределялась не
-- случайно — и любые выводы об эффекте недостоверны, каким бы красивым он ни
-- был. p-значение ниже 0,01 здесь означает «тест сломан, чинить систему
-- распределения», а не «эффект значим».

WITH assigned AS (
    SELECT a.variant
    FROM app.experiment_assignments a
    JOIN app.experiments e USING (experiment_id)
    WHERE e.experiment_code = :'exp_code'
),
counts AS (
    SELECT
        count(*) FILTER (WHERE variant = 'control')   AS n_control,
        count(*) FILTER (WHERE variant = 'treatment') AS n_treatment,
        count(*)                                      AS n_total
    FROM assigned
)
SELECT
    n_control                                                      AS "Контроль",
    n_treatment                                                    AS "Тест",
    round(100.0 * n_treatment / n_total, 2)                        AS "Доля теста, %",
    round(marts.z_two_proportions(n_total / 2, n_total, n_treatment, n_total)::numeric, 3)
                                                                   AS "z",
    round(marts.p_value_two_sided(
            marts.z_two_proportions(n_total / 2, n_total, n_treatment, n_total))::numeric, 4)
                                                                   AS "p-значение",
    CASE WHEN marts.p_value_two_sided(
                marts.z_two_proportions(n_total / 2, n_total, n_treatment, n_total)) < 0.01
         THEN 'ТРАФИК РАСПРЕДЕЛЁН НЕВЕРНО'
         ELSE 'расщепление в норме' END                            AS "Вывод"
FROM counts;

\echo ''
\echo '=== 7.3 Результаты по метрикам ==='
-- Основная метрика помечена звёздочкой. Для остальных p-значение приведено
-- справочно: тест не планировался под их чувствительность, и требовать от них
-- значимости нечестно — об этом отдельно в выводе ниже.

WITH assigned AS (
    SELECT a.variant, u.*
    FROM app.experiment_assignments a
    JOIN app.experiments e USING (experiment_id)
    JOIN marts.dim_user u ON u.user_id = a.user_id
    WHERE e.experiment_code = :'exp_code'
      AND u.is_matured
),
metrics AS (
    SELECT 1 AS ord, '* Активация за 7 дней' AS metric,
           count(*) FILTER (WHERE variant = 'control')                          AS n1,
           count(*) FILTER (WHERE variant = 'control'   AND is_activated)       AS x1,
           count(*) FILTER (WHERE variant = 'treatment')                        AS n2,
           count(*) FILTER (WHERE variant = 'treatment' AND is_activated)       AS x2
    FROM assigned
    UNION ALL
    SELECT 2, 'Прошли онбординг',
           count(*) FILTER (WHERE variant = 'control'),
           count(*) FILTER (WHERE variant = 'control'   AND onboarding_completed_at IS NOT NULL),
           count(*) FILTER (WHERE variant = 'treatment'),
           count(*) FILTER (WHERE variant = 'treatment' AND onboarding_completed_at IS NOT NULL)
    FROM assigned
    UNION ALL
    SELECT 3, 'Создали проект',
           count(*) FILTER (WHERE variant = 'control'),
           count(*) FILTER (WHERE variant = 'control'   AND first_project_at IS NOT NULL),
           count(*) FILTER (WHERE variant = 'treatment'),
           count(*) FILTER (WHERE variant = 'treatment' AND first_project_at IS NOT NULL)
    FROM assigned
    UNION ALL
    SELECT 4, 'Оплатили после триала',
           count(*) FILTER (WHERE variant = 'control'),
           count(*) FILTER (WHERE variant = 'control'   AND is_converted),
           count(*) FILTER (WHERE variant = 'treatment'),
           count(*) FILTER (WHERE variant = 'treatment' AND is_converted)
    FROM assigned
)
SELECT
    metric                                                          AS "Метрика",
    round(100.0 * x1 / n1, 1)                                       AS "Контроль, %",
    round(100.0 * x2 / n2, 1)                                       AS "Тест, %",
    round(100.0 * x2 / n2 - 100.0 * x1 / n1, 1)                     AS "Разница, п.п.",
    round((100 * marts.ci95_diff_proportions(x1, n1, x2, n2, 'low'))::numeric, 1)  AS "ДИ снизу",
    round((100 * marts.ci95_diff_proportions(x1, n1, x2, n2, 'high'))::numeric, 1) AS "ДИ сверху",
    round(marts.z_two_proportions(x1, n1, x2, n2)::numeric, 2)      AS "z",
    round(marts.p_value_two_sided(marts.z_two_proportions(x1, n1, x2, n2))::numeric, 4)
                                                                    AS "p",
    CASE WHEN marts.p_value_two_sided(marts.z_two_proportions(x1, n1, x2, n2)) < 0.05
         THEN 'значимо' ELSE 'не значимо' END                       AS "При α = 0,05"
FROM metrics
ORDER BY ord;

\echo ''
\echo '=== 7.4 Какой эффект тест вообще способен был увидеть ==='
-- Обратная задача к расчёту размера выборки: при фактическом размере групп и
-- базовом уровне метрики — какую минимальную разницу тест различил бы с
-- вероятностью 80 % (MDE).
--
-- Значимость и мощность — РАЗНЫЕ вещи, и их постоянно путают. Значимость
-- отвечает на вопрос «мог ли такой результат получиться при отсутствии
-- эффекта», мощность — «заметил бы тест эффект, если бы он был». Отсюда два
-- случая, которые читаются по-разному:
--
--   • Эффект НЕ значим и меньше MDE — это «не хватило данных», а не «эффекта
--     нет». Тест надо продлить, а не закрывать.
--   • Эффект значим, но меньше MDE — так тоже бывает, и это повод насторожиться:
--     при недостаточной мощности проходят через порог значимости в основном
--     случайно завышенные оценки. Ожидать, что раскатка на всех даст ровно
--     такой же прирост, не стоит; эффект скорее есть, но меньше измеренного.

WITH assigned AS (
    SELECT a.variant, u.*
    FROM app.experiment_assignments a
    JOIN app.experiments e USING (experiment_id)
    JOIN marts.dim_user u ON u.user_id = a.user_id
    WHERE e.experiment_code = :'exp_code' AND u.is_matured
),
params AS (
    SELECT
        count(*) FILTER (WHERE variant = 'control')                     AS n1,
        count(*) FILTER (WHERE variant = 'treatment')                   AS n2,
        avg(CASE WHEN is_activated THEN 1.0 ELSE 0 END)
            FILTER (WHERE variant = 'control')                          AS p_act,
        avg(CASE WHEN is_converted THEN 1.0 ELSE 0 END)
            FILTER (WHERE variant = 'control')                          AS p_conv,
        avg(CASE WHEN is_activated THEN 1.0 ELSE 0 END)
            FILTER (WHERE variant = 'treatment')
      - avg(CASE WHEN is_activated THEN 1.0 ELSE 0 END)
            FILTER (WHERE variant = 'control')                          AS obs_act,
        avg(CASE WHEN is_converted THEN 1.0 ELSE 0 END)
            FILTER (WHERE variant = 'treatment')
      - avg(CASE WHEN is_converted THEN 1.0 ELSE 0 END)
            FILTER (WHERE variant = 'control')                          AS obs_conv
    FROM assigned
),
mde AS (
    -- MDE = (z(0,975) + z(0,8)) * корень(2 p (1-p) / n) = 2,8016 * SE
    SELECT
        'Активация' AS metric, n1, n2, p_act AS p, obs_act AS observed,
        2.8016 * sqrt(2 * p_act * (1 - p_act) / ((n1 + n2) / 2.0)) AS mde
    FROM params
    UNION ALL
    SELECT
        'Оплата', n1, n2, p_conv, obs_conv,
        2.8016 * sqrt(2 * p_conv * (1 - p_conv) / ((n1 + n2) / 2.0))
    FROM params
)
SELECT
    metric                                        AS "Метрика",
    (n1 + n2) / 2                                 AS "Размер группы",
    round(100 * p, 1)                             AS "База, %",
    round(100 * mde, 2)                           AS "Различимый эффект, п.п.",
    round(100 * observed, 2)                      AS "Наблюдаемый эффект, п.п.",
    CASE WHEN observed >= mde
         THEN 'эффект выше порога: измерению можно верить'
         ELSE 'эффект ниже порога: оценка завышена, нужен повтор' END AS "Трактовка"
FROM mde;

\echo ''
\echo '=== 7.5 Разрез по каналам (только как гипотеза на будущее) ==='
-- Семь каналов — семь сравнений, и при уровне 0,05 одно «значимое» различие
-- ожидается случайно примерно в трети таких разборов. Ни одна строка отсюда
-- не может быть выводом эксперимента: это материал для следующего теста.

WITH assigned AS (
    SELECT a.variant, u.*
    FROM app.experiment_assignments a
    JOIN app.experiments e USING (experiment_id)
    JOIN marts.dim_user u ON u.user_id = a.user_id
    WHERE e.experiment_code = :'exp_code' AND u.is_matured
),
by_channel AS (
    SELECT
        channel_name,
        count(*) FILTER (WHERE variant = 'control')                    AS n1,
        count(*) FILTER (WHERE variant = 'control'   AND is_activated) AS x1,
        count(*) FILTER (WHERE variant = 'treatment')                  AS n2,
        count(*) FILTER (WHERE variant = 'treatment' AND is_activated) AS x2
    FROM assigned
    GROUP BY channel_name
)
SELECT
    channel_name                                                 AS "Канал",
    n1 + n2                                                      AS "Наблюдений",
    round(100.0 * x1 / nullif(n1, 0), 1)                         AS "Контроль, %",
    round(100.0 * x2 / nullif(n2, 0), 1)                         AS "Тест, %",
    round(100.0 * x2 / nullif(n2, 0) - 100.0 * x1 / nullif(n1, 0), 1) AS "Разница, п.п.",
    round(marts.p_value_two_sided(marts.z_two_proportions(x1, n1, x2, n2))::numeric, 3) AS "p"
FROM by_channel
WHERE n1 > 0 AND n2 > 0
ORDER BY "Разница, п.п." DESC;
