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
    channel_code    text          NOT NULL UNIQUE,
    channel_name    text          NOT NULL,
    channel_group   text          NOT NULL,      -- paid | organic | referral
    cac_rub         numeric(10,2) NOT NULL,      -- стоимость привлечения одной регистрации
    CONSTRAINT channels_group_chk CHECK (channel_group IN ('paid','organic','referral'))
);

COMMENT ON COLUMN app.channels.cac_rub IS
    'Стоимость привлечения одной РЕГИСТРАЦИИ (не платящего клиента). Плановая ставка из маркетинга.';

-- -----------------------------------------------------------------------------
-- Пользователи
-- -----------------------------------------------------------------------------

CREATE TABLE app.users (
    user_id       integer   PRIMARY KEY,
    signed_up_at  timestamp NOT NULL,
    channel_id    smallint  NOT NULL REFERENCES app.channels(channel_id),
    country_code  char(2)   NOT NULL,
    company_size  text      NOT NULL,            -- 1 | 2-10 | 11-50 | 51-200 | 200+
    is_b2b        boolean   NOT NULL,            -- регистрация с корпоративного домена
    CONSTRAINT users_company_size_chk
        CHECK (company_size IN ('1','2-10','11-50','51-200','200+'))
);

CREATE INDEX users_signed_up_at_idx ON app.users (signed_up_at);
CREATE INDEX users_channel_id_idx   ON app.users (channel_id);

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
    cancel_reason     text,
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
    user_id      integer   NOT NULL REFERENCES app.users(user_id),
    occurred_at  timestamp NOT NULL,
    event_name   text      NOT NULL,
    platform     text      NOT NULL              -- web | mobile | api
);

CREATE INDEX events_user_time_idx ON app.events (user_id, occurred_at);
CREATE INDEX events_name_time_idx ON app.events (event_name, occurred_at);

COMMENT ON TABLE app.events IS
    'Сырой лог продуктовых событий (аналог выгрузки из трекера). Одна строка — одно действие.';

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
