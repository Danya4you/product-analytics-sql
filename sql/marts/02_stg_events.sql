-- =============================================================================
-- marts/02_stg_events.sql — чистый лог событий
--
-- Единственное место, где разбираются дефекты сырого лога. Всё, что выше по
-- течению, читает эту витрину и больше не думает ни о дублях, ни о служебных
-- аккаунтах. Если чистку размазать по аналитическим запросам, рано или поздно
-- один из них её забудет — и разойдётся с остальными на пару процентов, что
-- заметят не сразу и не все.
--
-- Что убирается:
--
--   1. ДУБЛИ ОТ РЕТРАЕВ. Клиент не дождался подтверждения и отправил событие
--      повторно. В хранилище легли две строки: разные event_id, одинаковый
--      event_uid. Дедупликация идёт по ключу клиента, а не по всей строке:
--      время доставки у копий разное, и сравнение строк целиком их не поймает.
--      Оставляем первую доставку — она ближе к моменту действия.
--
--   2. СЛУЖЕБНЫЕ АККАУНТЫ. Сотрудники и тестовые прогоны. От обычных
--      пользователей отличаются только каналом привлечения. Оставить их —
--      значит занизить конверсию: в продукт заходят, платить не идут.
--
-- Чего эта витрина НЕ делает: не отбрасывает поздно доехавшие события.
-- Опоздание — не дефект, а свойство сбора данных, и работать с ним надо явно,
-- через ingested_at (см. sql/analysis/00_data_hygiene.sql).
-- =============================================================================

\set ON_ERROR_STOP on

DROP MATERIALIZED VIEW IF EXISTS marts.stg_events CASCADE;

CREATE MATERIALIZED VIEW marts.stg_events AS
SELECT DISTINCT ON (e.event_uid)
    e.event_id,
    e.event_uid,
    e.user_id,
    e.occurred_at,
    e.ingested_at,
    e.event_name,
    e.platform
FROM app.events   e
JOIN app.users    u USING (user_id)
JOIN app.channels c USING (channel_id)
WHERE c.channel_code <> 'internal'
ORDER BY e.event_uid, e.ingested_at, e.event_id;

CREATE UNIQUE INDEX stg_events_uid_pk    ON marts.stg_events (event_uid);
CREATE INDEX stg_events_user_time_idx    ON marts.stg_events (user_id, occurred_at);
CREATE INDEX stg_events_name_time_idx    ON marts.stg_events (event_name, occurred_at);

COMMENT ON MATERIALIZED VIEW marts.stg_events IS
    'Лог событий после чистки: дубли ретраев схлопнуты по event_uid, служебные аккаунты исключены. Все витрины читают его, а не app.events.';

ANALYZE marts.stg_events;
