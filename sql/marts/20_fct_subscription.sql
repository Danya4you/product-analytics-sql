-- =============================================================================
-- marts/20_fct_subscription.sql — подписка целиком: срок жизни, MRR, выручка
--
-- Одна строка на подписку (включая те, что умерли на триале). Здесь сведены
-- три источника: сама подписка, лог её событий и платежи.
--
-- Про MRR. В app.subscriptions лежит ТЕКУЩИЙ тариф, поэтому считать по нему
-- деньги за прошлые месяцы нельзя: апгрейд задним числом перепишет историю.
-- Первый и последний MRR берутся из лога событий.
-- =============================================================================

\set ON_ERROR_STOP on

DROP MATERIALIZED VIEW IF EXISTS marts.fct_subscription CASCADE;

CREATE MATERIALIZED VIEW marts.fct_subscription AS
WITH plan_at_convert AS (
    SELECT DISTINCT ON (se.subscription_id)
        se.subscription_id,
        se.plan_id      AS first_plan_id,
        se.mrr_after_rub AS first_mrr_rub
    FROM app.subscription_events se
    WHERE se.event_type = 'convert'
    ORDER BY se.subscription_id, se.occurred_at
),
plan_last AS (
    -- последнее состояние до отмены: mrr_after у cancel равен нулю, он не нужен
    SELECT DISTINCT ON (se.subscription_id)
        se.subscription_id,
        se.plan_id       AS last_plan_id,
        se.mrr_after_rub AS last_mrr_rub
    FROM app.subscription_events se
    WHERE se.event_type IN ('convert','upgrade','downgrade','renew')
    ORDER BY se.subscription_id, se.occurred_at DESC
),
plan_changes AS (
    SELECT
        subscription_id,
        count(*) FILTER (WHERE event_type = 'upgrade')   AS upgrades,
        count(*) FILTER (WHERE event_type = 'downgrade') AS downgrades,
        count(*) FILTER (WHERE event_type = 'renew')     AS renewals
    FROM app.subscription_events
    GROUP BY subscription_id
),
money AS (
    SELECT
        subscription_id,
        -- у возвратов amount_rub отрицательный, поэтому сумма и есть чистая выручка
        sum(amount_rub) FILTER (WHERE status IN ('succeeded','refunded')) AS revenue_rub,
        count(*)        FILTER (WHERE status = 'succeeded')               AS payments_ok,
        count(*)        FILTER (WHERE status = 'failed')                  AS payments_failed,
        count(*)        FILTER (WHERE status = 'refunded')                AS refunds
    FROM app.payments
    GROUP BY subscription_id
)
SELECT
    s.subscription_id,
    s.user_id,
    s.status,
    s.seats,
    s.cancel_reason,

    s.trial_started_at,
    s.trial_ended_at,
    s.started_at,
    s.ended_at,

    (s.started_at IS NOT NULL)                    AS is_converted,
    (s.status = 'active')                         AS is_active,

    pc.first_plan_id,
    fp.plan_code                                  AS first_plan_code,
    fp.plan_name                                  AS first_plan_name,
    fp.billing_period                             AS first_billing_period,
    pc.first_mrr_rub,

    pl.last_plan_id,
    lp.plan_code                                  AS last_plan_code,
    CASE WHEN s.status = 'active' THEN pl.last_mrr_rub ELSE 0 END AS current_mrr_rub,

    coalesce(ch.upgrades, 0)                      AS upgrades,
    coalesce(ch.downgrades, 0)                    AS downgrades,
    coalesce(ch.renewals, 0)                      AS renewals,

    coalesce(m.revenue_rub, 0)                    AS revenue_rub,
    coalesce(m.payments_ok, 0)                    AS payments_ok,
    coalesce(m.payments_failed, 0)                AS payments_failed,
    coalesce(m.refunds, 0)                        AS refunds,

    date_trunc('month', s.started_at)::date       AS paid_cohort_month,
    date_trunc('month', s.ended_at)::date         AS churn_month,

    -- срок жизни платного периода в днях; у активных — до даты среза
    CASE WHEN s.started_at IS NOT NULL
         THEN extract(day FROM coalesce(s.ended_at, marts.snapshot_ts()) - s.started_at)::int
    END                                           AS tenure_days,
    CASE WHEN s.started_at IS NOT NULL
         THEN round(extract(epoch FROM coalesce(s.ended_at, marts.snapshot_ts()) - s.started_at)
                    / 2629746.0, 2)
    END                                           AS tenure_months
FROM app.subscriptions       s
LEFT JOIN plan_at_convert    pc USING (subscription_id)
LEFT JOIN plan_last          pl USING (subscription_id)
LEFT JOIN plan_changes       ch USING (subscription_id)
LEFT JOIN money              m  USING (subscription_id)
LEFT JOIN app.plans          fp ON fp.plan_id = pc.first_plan_id
LEFT JOIN app.plans          lp ON lp.plan_id = pl.last_plan_id;

CREATE UNIQUE INDEX fct_subscription_pk       ON marts.fct_subscription (subscription_id);
CREATE INDEX        fct_subscription_user_idx ON marts.fct_subscription (user_id);
CREATE INDEX        fct_subscription_cohort_idx ON marts.fct_subscription (paid_cohort_month);

COMMENT ON MATERIALIZED VIEW marts.fct_subscription IS
    'Подписка целиком: срок жизни платного периода, первый и текущий MRR, собранная выручка.';
COMMENT ON COLUMN marts.fct_subscription.tenure_months IS
    'Длительность платного периода в средних месяцах (2 629 746 секунд). У активных считается до даты среза, поэтому это оценка снизу.';
COMMENT ON COLUMN marts.fct_subscription.revenue_rub IS
    'Сумма успешных списаний минус возвраты. Неудачные попытки не учитываются.';
