-- =============================================================================
-- marts/02_stg_events.sql — чистый лог событий
--
-- Единственное место, где разбираются дефекты сырого лога. Всё, что выше по
-- течению, читает эту витрину и больше не думает ни о дублях, ни о ботах, ни о
-- переименованных событиях. Если чистку размазать по аналитическим запросам,
-- рано или поздно один из них её забудет — и разойдётся с остальными на пару
-- процентов, что заметят не сразу и не все.
--
-- Что здесь происходит:
--
--   1. СКЛЕЙКА. Событиям без user_id проставляется владелец устройства. Так
--      анонимный просмотр страницы тарифов до регистрации становится частью
--      истории конкретного человека.
--
--   2. ОТСЕВ БОТОВ И СЛУЧАЙНЫХ ПОСЕТИТЕЛЕЙ. Устройство, на котором никто
--      никогда не входил в аккаунт, связать не с кем. Такие события уходят —
--      не по эвристике «слишком часто ходит», а по отсутствию владельца.
--
--   3. СЛУЖЕБНЫЕ АККАУНТЫ. Сотрудники на домене компании. В продукт заходят,
--      платить не идут, конверсию занижают.
--
--   4. ПЕРЕИМЕНОВАННОЕ СОБЫТИЕ. С 15 января по 5 февраля 2026 года мобильный
--      клиент слал task_create вместо task_created. Без этой склейки в январе
--      образуется провал активации, которого не было: продукт не менялся,
--      менялся трекинг. Такие вещи чинят в staging и обязательно комментируют
--      датами — иначе через полгода никто не вспомнит, откуда взялось условие.
--
--   5. ДЕДУПЛИКАЦИЯ. Ретраи трекера: разные event_id, один event_uid.
--      Оставляем первую доставку — она ближе к моменту действия.
--
-- Чего витрина НЕ делает: не отбрасывает поздно доехавшие события. Опоздание —
-- не дефект, а свойство сбора данных, и работать с ним надо явно, через
-- ingested_at (см. sql/analysis/00_data_hygiene.sql).
-- =============================================================================

\set ON_ERROR_STOP on

DROP MATERIALIZED VIEW IF EXISTS marts.stg_events CASCADE;

CREATE MATERIALIZED VIEW marts.stg_events AS
SELECT DISTINCT ON (e.event_uid)
    e.event_id,
    e.event_uid,
    e.device_id,
    coalesce(e.user_id, i.user_id) AS user_id,
    (e.user_id IS NULL)            AS stitched,     -- событие связано склейкой, а не напрямую
    e.occurred_at,
    e.ingested_at,
    CASE WHEN e.event_name = 'task_create' THEN 'task_created' ELSE e.event_name END
                                   AS event_name,
    (e.event_name = 'task_create')  AS renamed,     -- попало в окно сломанного трекинга
    e.platform
FROM app.events        e
JOIN marts.stg_identity i ON i.device_id = e.device_id
JOIN app.users          u ON u.user_id = coalesce(e.user_id, i.user_id)
WHERE u.email_domain <> 'timeline.ru'
ORDER BY e.event_uid, e.ingested_at, e.event_id;

CREATE UNIQUE INDEX stg_events_uid_pk    ON marts.stg_events (event_uid);
CREATE INDEX stg_events_user_time_idx    ON marts.stg_events (user_id, occurred_at);
CREATE INDEX stg_events_name_time_idx    ON marts.stg_events (event_name, occurred_at);

COMMENT ON MATERIALIZED VIEW marts.stg_events IS
    'Лог событий после чистки: анонимные сессии склеены с аккаунтами, боты и служебные аккаунты убраны, переименованное событие приведено к общему имени, дубли ретраев схлопнуты.';
COMMENT ON COLUMN marts.stg_events.stitched IS
    'Событие связано с пользователем по устройству, а не пришло с user_id. Такие события происходили ДО регистрации.';

ANALYZE marts.stg_events;
