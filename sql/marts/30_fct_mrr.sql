-- =============================================================================
-- marts/30_fct_mrr.sql — движения MRR и помесячный срез подписок
--
-- Две витрины про деньги:
--
--   fct_mrr_movement        — одна строка на изменение MRR (приход, расширение,
--                             сжатие, отток). Складывается в водопад и в
--                             накопленный MRR.
--   fct_subscription_month  — MRR каждой подписки на конец каждого месяца жизни.
--                             Нужен для когортного удержания выручки.
--
-- Почему движения считаются из лога событий, а не из разницы помесячных
-- срезов: подписка, которая пришла и ушла внутри одного календарного месяца,
-- при сравнении срезов исчезает бесследно — в обоих месяцах у неё ноль.
-- В логе такие видны как пара convert + cancel и попадают и в приход, и в отток.
-- =============================================================================

\set ON_ERROR_STOP on

DROP MATERIALIZED VIEW IF EXISTS marts.fct_mrr_movement CASCADE;

CREATE MATERIALIZED VIEW marts.fct_mrr_movement AS
WITH prior_subs AS (
    -- была ли у пользователя подписка, закончившаяся раньше этой: отличает
    -- вернувшегося клиента от нового
    SELECT
        s.subscription_id,
        s.user_id,
        s.started_at,
        exists (
            SELECT 1
            FROM app.subscriptions p
            WHERE p.user_id  = s.user_id
              AND p.subscription_id <> s.subscription_id
              AND p.ended_at IS NOT NULL
              AND p.ended_at < s.started_at
        ) AS is_returning
    FROM app.subscriptions s
    WHERE s.started_at IS NOT NULL
)
SELECT
    se.event_id,
    se.subscription_id,
    s.user_id,
    se.occurred_at,
    date_trunc('month', se.occurred_at)::date AS month,
    CASE se.event_type
        WHEN 'convert'   THEN CASE WHEN ps.is_returning THEN 'reactivation' ELSE 'new' END
        WHEN 'upgrade'   THEN 'expansion'
        WHEN 'downgrade' THEN 'contraction'
        WHEN 'cancel'    THEN 'churn'
    END                                       AS movement_type,
    se.mrr_after_rub - se.mrr_before_rub      AS mrr_delta_rub
FROM app.subscription_events se
JOIN app.subscriptions s USING (subscription_id)
JOIN prior_subs         ps USING (subscription_id)
WHERE se.event_type IN ('convert','upgrade','downgrade','cancel');
-- renew исключён намеренно: продление не меняет MRR, а только подтверждает его

CREATE UNIQUE INDEX fct_mrr_movement_pk    ON marts.fct_mrr_movement (event_id);
CREATE INDEX        fct_mrr_movement_month ON marts.fct_mrr_movement (month, movement_type);

COMMENT ON MATERIALIZED VIEW marts.fct_mrr_movement IS
    'Изменения MRR по типам. Накопленная сумма mrr_delta_rub на конец месяца равна MRR компании.';
COMMENT ON COLUMN marts.fct_mrr_movement.movement_type IS
    'new — первая подписка клиента; reactivation — вернувшийся; expansion/contraction — смена тарифа; churn — отмена.';

-- -----------------------------------------------------------------------------

DROP MATERIALIZED VIEW IF EXISTS marts.fct_subscription_month CASCADE;

CREATE MATERIALIZED VIEW marts.fct_subscription_month AS
SELECT
    s.subscription_id,
    s.user_id,
    s.paid_cohort_month,
    m.month::date AS month,
    ((extract(year  FROM m.month) - extract(year  FROM s.paid_cohort_month)) * 12
   + (extract(month FROM m.month) - extract(month FROM s.paid_cohort_month)))::int AS month_index,
    coalesce(state.mrr_rub, 0) AS mrr_rub,
    s.first_mrr_rub
FROM marts.fct_subscription s
CROSS JOIN LATERAL generate_series(
        s.paid_cohort_month::timestamp,
        date_trunc('month', coalesce(s.ended_at, marts.snapshot_ts())),
        interval '1 month'
     ) AS m(month)
LEFT JOIN LATERAL (
    -- состояние подписки на конец месяца: последнее событие, поменявшее MRR
    SELECT se.mrr_after_rub AS mrr_rub
    FROM app.subscription_events se
    WHERE se.subscription_id = s.subscription_id
      AND se.event_type <> 'trial_start'
      AND se.occurred_at < m.month + interval '1 month'
    ORDER BY se.occurred_at DESC
    LIMIT 1
) AS state ON true
WHERE s.is_converted;

CREATE UNIQUE INDEX fct_sub_month_pk     ON marts.fct_subscription_month (subscription_id, month);
CREATE INDEX        fct_sub_month_cohort ON marts.fct_subscription_month (paid_cohort_month, month_index);

COMMENT ON MATERIALIZED VIEW marts.fct_subscription_month IS
    'MRR подписки на конец каждого месяца её жизни. Нулевой месяц — месяц первой оплаты.';
COMMENT ON COLUMN marts.fct_subscription_month.first_mrr_rub IS
    'MRR в момент оплаты. База когортного удержания выручки берётся отсюда, а не из среза нулевого месяца: подписка, ушедшая в том же месяце, иначе дала бы нулевую базу.';
