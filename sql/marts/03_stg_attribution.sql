-- =============================================================================
-- marts/03_stg_attribution.sql — восстановление канала привлечения
--
-- В сыром слое канала у пользователя НЕТ. Продукт его не знает: человек кликнул
-- по рекламе, походил по сайту, через неделю вернулся и зарегистрировался.
-- Всё, что осталось, — касания на устройстве, которые надо связать с аккаунтом
-- и свести к одному ответу.
--
-- Ответ зависит от МОДЕЛИ, а не от данных, поэтому здесь считаются две сразу:
--
--   • last non-direct click — последнее касание перед регистрацией, кроме
--     прямых заходов. Отраслевой стандарт по умолчанию: отвечает на вопрос
--     «что привело человека к решению».
--   • first touch — первое касание. Отвечает на другой вопрос: «откуда он
--     вообще узнал о продукте».
--
-- Обе модели одинаково «правильные» и дают разные ответы. Аналитик обязан
-- назвать выбранную и показать, насколько от неё зависит вывод — этим занят
-- раздел 4.1 в sql/analysis/04_unit_economics.sql.
--
-- Окно оглядки — 30 дней. Тоже решение, а не факт: касание двухмесячной
-- давности вряд ли объясняет сегодняшнюю регистрацию, но граница условна.
--
-- ТРИ ИСХОДА, а не один:
--   • канал определён;
--   • были только прямые заходы → direct (человек пришёл сам, источник
--     неизвестен);
--   • касаний не сохранилось вовсе → unknown. Куки заблокированы, метки
--     потерялись на редиректе, переход из мессенджера. Это не чинится
--     запросом — это свойство сбора данных, и такие регистрации нельзя ни
--     выкидывать, ни молча приписывать к «прямым».
-- =============================================================================

\set ON_ERROR_STOP on

DROP MATERIALIZED VIEW IF EXISTS marts.stg_attribution CASCADE;

CREATE MATERIALIZED VIEW marts.stg_attribution AS
WITH touches AS (
    -- касания, связанные с пользователем через его устройства и попавшие в окно
    SELECT
        i.user_id,
        t.occurred_at,
        t.channel_id,
        t.campaign,
        t.is_direct
    FROM app.touchpoints   t
    JOIN marts.stg_identity i ON i.device_id = t.device_id
    JOIN app.users          u ON u.user_id = i.user_id
    WHERE t.occurred_at <= u.signed_up_at
      AND t.occurred_at >= u.signed_up_at - interval '30 days'
),
last_non_direct AS (
    SELECT DISTINCT ON (user_id)
        user_id, channel_id, campaign, occurred_at
    FROM touches
    WHERE NOT is_direct
    ORDER BY user_id, occurred_at DESC
),
first_non_direct AS (
    SELECT DISTINCT ON (user_id)
        user_id, channel_id
    FROM touches
    WHERE NOT is_direct
    ORDER BY user_id, occurred_at
),
totals AS (
    SELECT user_id, count(*) AS touches_cnt,
           count(*) FILTER (WHERE NOT is_direct) AS non_direct_cnt
    FROM touches
    GROUP BY user_id
),
codes AS (
    SELECT
        (SELECT channel_id FROM app.channels WHERE channel_code = 'direct')  AS direct_id,
        (SELECT channel_id FROM app.channels WHERE channel_code = 'unknown') AS unknown_id
)
SELECT
    u.user_id,
    -- основная модель: последнее непрямое касание
    CASE
        WHEN l.channel_id IS NOT NULL              THEN l.channel_id
        WHEN coalesce(t.touches_cnt, 0) > 0        THEN c.direct_id
        ELSE                                            c.unknown_id
    END                                            AS channel_id,
    -- альтернативная модель: первое непрямое касание
    CASE
        WHEN f.channel_id IS NOT NULL              THEN f.channel_id
        WHEN coalesce(t.touches_cnt, 0) > 0        THEN c.direct_id
        ELSE                                            c.unknown_id
    END                                            AS channel_id_first_touch,
    l.campaign                                     AS campaign,
    coalesce(t.touches_cnt, 0)                     AS touches_cnt,
    coalesce(t.non_direct_cnt, 0)                  AS non_direct_touches,
    -- сколько прошло от решающего касания до регистрации: если много,
    -- атрибуция «последним кликом» становится натяжкой
    extract(epoch FROM u.signed_up_at - l.occurred_at) / 3600 AS hours_to_signup
FROM app.users           u
CROSS JOIN codes         c
LEFT JOIN totals         t USING (user_id)
LEFT JOIN last_non_direct  l USING (user_id)
LEFT JOIN first_non_direct f USING (user_id)
WHERE u.email_domain <> 'timeline.ru';

CREATE UNIQUE INDEX stg_attribution_pk      ON marts.stg_attribution (user_id);
CREATE INDEX stg_attribution_channel_idx    ON marts.stg_attribution (channel_id);

COMMENT ON MATERIALIZED VIEW marts.stg_attribution IS
    'Канал привлечения, восстановленный из касаний. Две модели сразу: last non-direct click (основная) и first touch (для проверки устойчивости выводов).';
COMMENT ON COLUMN marts.stg_attribution.hours_to_signup IS
    'Часов от решающего касания до регистрации. Чем больше, тем слабее связь между каналом и решением.';
