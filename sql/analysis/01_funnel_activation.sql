-- =============================================================================
-- 01 — Воронка от регистрации до оплаты и цена активации
--
-- Вопрос: где именно теряются пользователи по пути к оплате и насколько
-- активация в первую неделю определяет исход.
--
-- Оговорка по выборке. Берутся только пользователи, зарегистрировавшиеся не
-- позже чем за 30 дней до даты среза. У остальных четырнадцатидневный триал
-- ещё не закончился или закончился вчера — включать их в знаменатель значит
-- занижать конверсию последних недель.
-- =============================================================================

\pset border 2

\echo ''
\echo '=== 1.1 Сквозная воронка ==='
-- Шаги строго вложены: каждый следующий — подмножество предыдущего, поэтому
-- конверсия из шага в шаг не может превысить 100 %. Прохождение онбординга в
-- воронку не включено намеренно: это необязательный шаг, проект можно создать
-- и мимо него. Если поставить его четвёртым, конверсия «онбординг → проект»
-- получится 111 %, и таблица начнёт врать. Онбординг разобран отдельно в 1.5.

WITH base AS (
    SELECT * FROM marts.dim_user WHERE is_matured
),
steps AS (
    SELECT 1 AS step_no, 'Регистрация'                AS step, count(*) AS users FROM base
    UNION ALL
    SELECT 2, 'Подтвердил почту',      count(*) FILTER (WHERE email_confirmed_at IS NOT NULL) FROM base
    UNION ALL
    SELECT 3, 'Создал проект',         count(*) FILTER (WHERE first_project_at IS NOT NULL)   FROM base
    UNION ALL
    SELECT 4, 'Активация (3+ задачи)', count(*) FILTER (WHERE is_activated)                   FROM base
    UNION ALL
    SELECT 5, 'Оплатил',               count(*) FILTER (WHERE is_converted)                   FROM base
)
SELECT
    step_no                                                              AS "№",
    step                                                                 AS "Шаг",
    users                                                                AS "Пользователей",
    round(100.0 * users / first_value(users) OVER w, 1)                  AS "От старта, %",
    round(100.0 * users / lag(users) OVER w, 1)                          AS "Из шага, %",
    lag(users) OVER w - users                                            AS "Потеряно"
FROM steps
WINDOW w AS (ORDER BY step_no)
ORDER BY step_no;

\echo ''
\echo '=== 1.2 Активация решает: что происходит после первой недели ==='
-- Один и тот же вопрос в двух разрезах сразу: доля оплативших и деньги.
-- Если разрыв держится и в конверсии, и в выручке — активация не просто
-- коррелирует с платящими, а отбирает другой по качеству сегмент.

WITH base AS (
    SELECT * FROM marts.dim_user WHERE is_matured
)
SELECT
    CASE WHEN b.is_activated THEN 'Активировались' ELSE 'Нет' END        AS "Сегмент",
    count(*)                                                             AS "Пользователей",
    round(100.0 * count(*) / sum(count(*)) OVER (), 1)                   AS "Доля, %",
    count(*) FILTER (WHERE b.is_converted)                               AS "Оплатили",
    round(100.0 * count(*) FILTER (WHERE b.is_converted) / count(*), 1)  AS "Конверсия, %",
    round(avg(b.tasks_first_7d), 1)                                      AS "Задач за 7 дней",
    round(coalesce(sum(s.revenue_rub), 0) / count(*))                    AS "Выручка на юзера, ₽"
FROM base b
LEFT JOIN marts.fct_subscription s ON s.user_id = b.user_id
GROUP BY b.is_activated
ORDER BY b.is_activated DESC;

\echo ''
\echo '=== 1.3 Воронка по каналам привлечения ==='
-- Каналы сравниваются не по объёму трафика, а по тому, что с этим трафиком
-- происходит дальше. Столбец «Активация→оплата» отвечает на отдельный вопрос:
-- канал приводит неподходящих людей или продукт не удерживает подходящих.

WITH base AS (
    SELECT * FROM marts.dim_user WHERE is_matured
)
SELECT
    channel_name                                                          AS "Канал",
    channel_group                                                         AS "Тип",
    count(*)                                                              AS "Регистраций",
    round(100.0 * count(*) FILTER (WHERE onboarding_completed_at IS NOT NULL)
          / count(*), 1)                                                  AS "Онбординг, %",
    round(100.0 * count(*) FILTER (WHERE is_activated) / count(*), 1)     AS "Активация, %",
    round(100.0 * count(*) FILTER (WHERE is_converted) / count(*), 1)     AS "Оплата, %",
    round(100.0 * count(*) FILTER (WHERE is_converted AND is_activated)
          / nullif(count(*) FILTER (WHERE is_activated), 0), 1)           AS "Активация→оплата, %"
FROM base
GROUP BY channel_name, channel_group
ORDER BY "Оплата, %" DESC;

\echo ''
\echo '=== 1.4 Порог активации: сколько задач достаточно ==='
-- Проверка самого определения активации: где на кривой «задач за первую неделю
-- → конверсия» находится перелом.
--
-- ЧЕСТНАЯ ОГОВОРКА. Данные синтетические, и порог в три задачи заложен в
-- генератор. Поэтому перелом здесь выглядит как ступенька, а не как плавный
-- изгиб. На живых данных этот же запрос дал бы сглаженную кривую, и порог
-- пришлось бы выбирать по балансу между охватом сегмента и разрывом конверсии.
-- Запрос показывает метод, а не открытие.

WITH base AS (
    SELECT * FROM marts.dim_user WHERE is_matured
)
SELECT
    CASE WHEN tasks_first_7d >= 10 THEN '10+' ELSE tasks_first_7d::text END AS "Задач за 7 дней",
    count(*)                                                                AS "Пользователей",
    round(100.0 * count(*) FILTER (WHERE is_converted) / count(*), 1)       AS "Конверсия, %",
    round(100.0 * count(*) FILTER (WHERE is_converted) / count(*)
          - lag(round(100.0 * count(*) FILTER (WHERE is_converted) / count(*), 1))
            OVER (ORDER BY least(tasks_first_7d, 10)), 1)                   AS "Прирост, п.п."
FROM base
GROUP BY least(tasks_first_7d, 10), CASE WHEN tasks_first_7d >= 10 THEN '10+' ELSE tasks_first_7d::text END
ORDER BY least(tasks_first_7d, 10);

\echo ''
\echo '=== 1.5 Онбординг: необязательный шаг с большим эффектом ==='
-- Онбординг проходят не все, и пропустившие его не отваливаются мгновенно —
-- они просто хуже доходят до активации. Сравнение в лоб здесь некорректно:
-- онбординг чаще проходят те, кто и так настроен серьёзно. Поэтому рядом
-- стоит контроль по каналу — если разрыв держится внутри каждого канала,
-- дело не только в отборе.

SELECT
    coalesce(channel_name, 'ВСЕ КАНАЛЫ')                                    AS "Канал",
    count(*) FILTER (WHERE onboarding_completed_at IS NOT NULL)             AS "Прошли",
    round(100.0 * count(*) FILTER (WHERE is_activated AND onboarding_completed_at IS NOT NULL)
          / nullif(count(*) FILTER (WHERE onboarding_completed_at IS NOT NULL), 0), 1)
                                                                            AS "Активация с ним, %",
    round(100.0 * count(*) FILTER (WHERE is_activated AND onboarding_completed_at IS NULL)
          / nullif(count(*) FILTER (WHERE onboarding_completed_at IS NULL), 0), 1)
                                                                            AS "Активация без, %",
    round(100.0 * count(*) FILTER (WHERE is_activated AND onboarding_completed_at IS NOT NULL)
          / nullif(count(*) FILTER (WHERE onboarding_completed_at IS NOT NULL), 0)
        - 100.0 * count(*) FILTER (WHERE is_activated AND onboarding_completed_at IS NULL)
          / nullif(count(*) FILTER (WHERE onboarding_completed_at IS NULL), 0), 1)
                                                                            AS "Разрыв, п.п."
FROM marts.dim_user
WHERE is_matured
GROUP BY GROUPING SETS ((channel_name), ())
ORDER BY "Разрыв, п.п." DESC NULLS LAST;
