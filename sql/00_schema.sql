-- =============================================================================
-- 00_schema.sql — сырой слой продуктовых данных SaaS «Тайм-лайн»
--
-- Схема app имитирует выгрузку из продакшн-БД и трекера событий: так данные
-- приходят аналитику в реальности — нормализованными, без предрасчитанных
-- метрик. Вся аналитика строится поверх, в схеме marts.
--
-- Скрипт идемпотентный: DROP SCHEMA ... CASCADE в начале, одна транзакция.
-- PostgreSQL 17.
-- =============================================================================

BEGIN;

DROP SCHEMA IF EXISTS app CASCADE;
CREATE SCHEMA app;

-- -----------------------------------------------------------------------------
-- Справочники
-- -----------------------------------------------------------------------------

CREATE TABLE app.plans (
    plan_id         smallint PRIMARY KEY,
    plan_code       text          NOT NULL UNIQUE,
    plan_name       text          NOT NULL,
    plan_rank       smallint      NOT NULL,      -- порядок тарифов: для upgrade/downgrade
    billing_period  text          NOT NULL,      -- monthly | annual
    price_rub       numeric(10,2) NOT NULL,      -- цена за период биллинга
    seats_included  smallint      NOT NULL,
    CONSTRAINT plans_billing_period_chk CHECK (billing_period IN ('monthly','annual')),
    CONSTRAINT plans_price_chk          CHECK (price_rub >= 0)
);

COMMENT ON TABLE  app.plans IS 'Тарифные планы. price_rub — цена за период биллинга, не за месяц.';
COMMENT ON COLUMN app.plans.plan_rank IS 'Ранг тарифа: классифицирует переход как upgrade или downgrade.';

CREATE TABLE app.channels (
    channel_id      smallint PRIMARY KEY,
    channel_code    text     NOT NULL UNIQUE,
    channel_name    text     NOT NULL,
    channel_group   text     NOT NULL,      -- paid | organic | referral | direct | unknown
    CONSTRAINT channels_group_chk
        CHECK (channel_group IN ('paid','organic','referral','direct','unknown'))
);

COMMENT ON TABLE app.channels IS
    'Справочник каналов. direct и unknown — не источники трафика, а исходы атрибуции: «зашёл напрямую» и «определить не удалось».';

-- Стоимости привлечения здесь НЕТ намеренно. В жизни она не лежит колонкой в
-- справочнике: расходы приходят из рекламных кабинетов суточными строками по
-- кампаниям (app.ad_spend), и сопоставить их с регистрациями можно только по
-- дате и каналу. Колонка cac_rub в справочнике — признак того, что кто-то уже
-- принял за аналитика несколько решений и не сказал каких.

CREATE TABLE app.ad_spend (
    spend_date   date     NOT NULL,
    channel_id   smallint NOT NULL REFERENCES app.channels(channel_id),
    campaign     text     NOT NULL,
    spend_rub    numeric(12,2) NOT NULL,
    clicks       integer  NOT NULL,
    impressions  bigint   NOT NULL,
    PRIMARY KEY (spend_date, channel_id, campaign),
    CONSTRAINT ad_spend_positive_chk CHECK (spend_rub >= 0 AND clicks >= 0)
);

CREATE INDEX ad_spend_channel_idx ON app.ad_spend (channel_id, spend_date);

COMMENT ON TABLE app.ad_spend IS
    'Суточные расходы из рекламных кабинетов. Гранулярность — день × канал × кампания; связи с конкретным пользователем нет и быть не может.';

-- -----------------------------------------------------------------------------
-- Маркетинговые касания
-- -----------------------------------------------------------------------------

CREATE TABLE app.touchpoints (
    touchpoint_id bigint    PRIMARY KEY,
    device_id     text      NOT NULL,
    occurred_at   timestamp NOT NULL,
    channel_id    smallint  NOT NULL REFERENCES app.channels(channel_id),
    campaign      text,
    is_direct     boolean   NOT NULL
);

CREATE INDEX touchpoints_device_idx ON app.touchpoints (device_id, occurred_at);

COMMENT ON TABLE app.touchpoints IS
    'Касания до регистрации. Привязаны к УСТРОЙСТВУ, а не к пользователю: в момент клика по рекламе аккаунта ещё нет. Связывание — задача marts.stg_events.';
COMMENT ON COLUMN app.touchpoints.is_direct IS
    'Прямой заход без источника. В моделях атрибуции такие касания обычно пропускают: они не объясняют, откуда человек узнал о продукте.';

-- -----------------------------------------------------------------------------
-- Пользователи
-- -----------------------------------------------------------------------------

CREATE TABLE app.users (
    user_id       integer   PRIMARY KEY,
    signed_up_at  timestamp NOT NULL,
    country_code  char(2)   NOT NULL,
    company_size  text      NOT NULL,       -- 1 | 2-10 | 11-50 | 51-200 | 200+
    email_domain  text      NOT NULL,
    CONSTRAINT users_company_size_chk
        CHECK (company_size IN ('1','2-10','11-50','51-200','200+'))
);

COMMENT ON TABLE app.users IS
    'Зарегистрированные аккаунты. Канала привлечения здесь НЕТ: продукт его не знает, он восстанавливается из касаний.';
COMMENT ON COLUMN app.users.email_domain IS
    'Домен почты. Единственный признак, по которому отличают компанию от частника и находят служебные аккаунты сотрудников (домен самой компании).';

CREATE INDEX users_signed_up_at_idx ON app.users (signed_up_at);
CREATE INDEX users_email_domain_idx ON app.users (email_domain);

-- -----------------------------------------------------------------------------
-- Подписки и их события
-- -----------------------------------------------------------------------------

CREATE TABLE app.subscriptions (
    subscription_id   integer   PRIMARY KEY,
    user_id           integer   NOT NULL REFERENCES app.users(user_id),
    plan_id           smallint  NOT NULL REFERENCES app.plans(plan_id),
    trial_started_at  timestamp NOT NULL,
    trial_ended_at    timestamp NOT NULL,
    started_at        timestamp,                 -- NULL = до платного периода не дошли
    ended_at          timestamp,                 -- NULL = активна на дату среза
    status            text      NOT NULL,        -- trial | trial_expired | active | churned
    cancel_reason_raw text,           -- ответ на опрос: чаще всего пустой
    seats             smallint  NOT NULL DEFAULT 1,
    CONSTRAINT subs_status_chk
        CHECK (status IN ('trial','trial_expired','active','churned')),
    CONSTRAINT subs_trial_order_chk CHECK (trial_ended_at >= trial_started_at),
    CONSTRAINT subs_paid_order_chk
        CHECK (ended_at IS NULL OR started_at IS NULL OR ended_at >= started_at),
    CONSTRAINT subs_active_has_start_chk
        CHECK (status NOT IN ('active','churned') OR started_at IS NOT NULL)
);

CREATE INDEX subs_user_id_idx    ON app.subscriptions (user_id);
CREATE INDEX subs_started_at_idx ON app.subscriptions (started_at);

COMMENT ON TABLE app.subscriptions IS
    'Одна строка — одна подписка. После оттока пользователь может завести вторую (реактивация).';
COMMENT ON COLUMN app.subscriptions.cancel_reason_raw IS
    'Сырой ответ из формы опроса при отмене. Пустой у пассивного оттока (никто ничего не отменял, просто не прошло списание) и у тех, кто закрыл форму. Регистр и формулировки не нормализованы.';
COMMENT ON COLUMN app.subscriptions.plan_id IS
    'ТЕКУЩИЙ тариф. История переходов — в subscription_events, поэтому MRR по этому полю не считают.';

CREATE TABLE app.subscription_events (
    event_id        bigint    PRIMARY KEY,
    subscription_id integer   NOT NULL REFERENCES app.subscriptions(subscription_id),
    occurred_at     timestamp NOT NULL,
    event_type      text      NOT NULL,          -- trial_start|convert|upgrade|downgrade|renew|cancel
    plan_id         smallint  REFERENCES app.plans(plan_id),
    mrr_before_rub  numeric(10,2) NOT NULL DEFAULT 0,
    mrr_after_rub   numeric(10,2) NOT NULL DEFAULT 0,
    CONSTRAINT sub_events_type_chk
        CHECK (event_type IN ('trial_start','convert','upgrade','downgrade','renew','cancel'))
);

CREATE INDEX sub_events_sub_idx  ON app.subscription_events (subscription_id, occurred_at);
CREATE INDEX sub_events_time_idx ON app.subscription_events (occurred_at);

COMMENT ON TABLE app.subscription_events IS
    'Лог изменений подписки. Источник истины для MRR-движений: new, expansion, contraction, churn.';
COMMENT ON COLUMN app.subscription_events.mrr_after_rub IS
    'MRR нормирован к месяцу: годовой тариф делится на 12, иначе помесячная динамика скачет.';

-- -----------------------------------------------------------------------------
-- Платежи
-- -----------------------------------------------------------------------------

CREATE TABLE app.payments (
    payment_id      bigint    PRIMARY KEY,
    subscription_id integer   NOT NULL REFERENCES app.subscriptions(subscription_id),
    paid_at         timestamp NOT NULL,
    amount_rub      numeric(10,2) NOT NULL,
    status          text      NOT NULL,          -- succeeded | failed | refunded
    attempt_no      smallint  NOT NULL DEFAULT 1, -- попытка списания, 2+ = повторное списание
    CONSTRAINT payments_status_chk CHECK (status IN ('succeeded','failed','refunded'))
);

CREATE INDEX payments_sub_idx  ON app.payments (subscription_id, paid_at);
CREATE INDEX payments_time_idx ON app.payments (paid_at);

COMMENT ON COLUMN app.payments.amount_rub IS
    'Фактическая сумма за период биллинга. У возвратов (refunded) сумма отрицательная.';

-- -----------------------------------------------------------------------------
-- Продуктовые события
-- -----------------------------------------------------------------------------

CREATE TABLE app.events (
    event_id     bigint    PRIMARY KEY,
    event_uid    text      NOT NULL,             -- идемпотентный ключ от клиента
    device_id    text      NOT NULL,             -- известен всегда, ещё до входа
    user_id      integer   REFERENCES app.users(user_id),  -- NULL до входа в аккаунт
    occurred_at  timestamp NOT NULL,             -- когда действие произошло
    ingested_at  timestamp NOT NULL,             -- когда строка доехала до хранилища
    event_name   text      NOT NULL,
    platform     text      NOT NULL,             -- web | mobile | api
    CONSTRAINT events_ingest_order_chk CHECK (ingested_at >= occurred_at)
);

CREATE INDEX events_user_time_idx ON app.events (user_id, occurred_at);
CREATE INDEX events_name_time_idx ON app.events (event_name, occurred_at);
CREATE INDEX events_uid_idx       ON app.events (event_uid);
CREATE INDEX events_device_idx    ON app.events (device_id, occurred_at);
CREATE INDEX events_ingested_idx  ON app.events (ingested_at);

COMMENT ON TABLE app.events IS
    'Сырой лог продуктовых событий. Одна строка — одна ДОСТАВЛЕННАЯ запись, а не одно действие: ретраи трекера кладут дубли. Чистая версия — marts.stg_events.';
COMMENT ON COLUMN app.events.user_id IS
    'Пустой у анонимных сессий: до входа в аккаунт продукт знает только устройство. Связывание с пользователем — отдельная задача, см. marts.stg_events.';
COMMENT ON COLUMN app.events.event_uid IS
    'Идемпотентный ключ, присвоенный клиентом. НЕ уникален в таблице: повторная доставка того же события приходит с тем же ключом и новым event_id. Ключ дедупликации.';
COMMENT ON COLUMN app.events.ingested_at IS
    'Момент попадания в хранилище. Отличается от occurred_at на секунды, иногда на дни — из-за этого отчёт за один и тот же день, построенный в разные даты, даёт разные числа.';

-- -----------------------------------------------------------------------------
-- A/B-эксперименты
-- -----------------------------------------------------------------------------

CREATE TABLE app.experiments (
    experiment_id    smallint  PRIMARY KEY,
    experiment_code  text      NOT NULL UNIQUE,
    experiment_name  text      NOT NULL,
    hypothesis       text      NOT NULL,
    primary_metric   text      NOT NULL,
    started_at       timestamp NOT NULL,
    ended_at         timestamp NOT NULL
);

CREATE TABLE app.experiment_assignments (
    experiment_id  smallint  NOT NULL REFERENCES app.experiments(experiment_id),
    user_id        integer   NOT NULL REFERENCES app.users(user_id),
    variant        text      NOT NULL,           -- control | treatment
    assigned_at    timestamp NOT NULL,
    PRIMARY KEY (experiment_id, user_id),
    CONSTRAINT assignments_variant_chk CHECK (variant IN ('control','treatment'))
);

CREATE INDEX assignments_user_idx ON app.experiment_assignments (user_id);

COMMIT;
