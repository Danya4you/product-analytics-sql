-- =============================================================================
-- marts/01_stg_identity.sql — связывание устройств с аккаунтами
--
-- Задача, с которой начинается любая продуктовая аналитика: события до входа в
-- аккаунт помечены только устройством, события после — пользователем. Пока
-- одно не связано с другим, воронка обрывается на регистрации, а весь
-- маркетинговый след (он весь до регистрации) висит в воздухе.
--
-- Правило простое: устройство принадлежит тому пользователю, который совершил
-- на нём больше всего действий. Оно устроено так, чтобы выдержать общее
-- устройство — рабочий компьютер, за которым сидели двое, — хотя в этих данных
-- таких нет. Настоящая система идентификации сложнее: там учитывают порядок
-- входов, срок жизни куки и явные связи из логина. Но именно этот вариант
-- покрывает большинство случаев и его легко объяснить.
--
-- Устройства, на которых никто никогда не входил в аккаунт, сюда не попадают.
-- Это боты, поисковые роботы и случайные посетители — связать их не с кем, и
-- дальше по течению они отсекаются сами.
-- =============================================================================

\set ON_ERROR_STOP on

DROP MATERIALIZED VIEW IF EXISTS marts.stg_identity CASCADE;

CREATE MATERIALIZED VIEW marts.stg_identity AS
WITH device_user AS (
    SELECT
        device_id,
        user_id,
        count(*) AS events_cnt
    FROM app.events
    WHERE user_id IS NOT NULL
    GROUP BY device_id, user_id
),
ranked AS (
    SELECT
        device_id,
        user_id,
        events_cnt,
        count(*)   OVER (PARTITION BY device_id) AS users_on_device,
        row_number() OVER (PARTITION BY device_id
                           ORDER BY events_cnt DESC, user_id) AS rn
    FROM device_user
)
SELECT
    device_id,
    user_id,
    events_cnt,
    (users_on_device > 1) AS device_shared
FROM ranked
WHERE rn = 1;

CREATE UNIQUE INDEX stg_identity_pk       ON marts.stg_identity (device_id);
CREATE INDEX        stg_identity_user_idx ON marts.stg_identity (user_id);

COMMENT ON MATERIALIZED VIEW marts.stg_identity IS
    'Устройство → аккаунт. Основа для склейки анонимных сессий и для привязки маркетинговых касаний к пользователю.';
COMMENT ON COLUMN marts.stg_identity.device_shared IS
    'На устройстве входили под разными аккаунтами. Связь выбрана по большинству событий и достоверна не полностью.';
