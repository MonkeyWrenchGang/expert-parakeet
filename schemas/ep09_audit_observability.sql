-- ============================================================
-- EP-08: Observability, Audit Logging & Infrastructure
-- Stories: S-08-01 through S-08-05
-- Design ref: §8 Implementation Phasing, NFR
-- ============================================================
-- PostgreSQL (Flyway migration: V5__audit_observability.sql)
--
-- This schema covers:
--   1. Immutable entity audit log  (S-08-03)
--   2. Resolution pipeline metrics ledger  (S-08-02) — summary table
--      (real-time metrics emitted to OpenTelemetry / Prometheus)
--   3. Load test run registry  (S-08-05)
--
-- OpenTelemetry traces and Grafana dashboards are infrastructure
-- concerns (Helm chart, EP-08 S-08-02) — not represented in DDL.
-- ============================================================

-- ----------------------------------------------------------------
-- ENTITY AUDIT LOG  (S-08-03)
-- Immutable record of every state change to idr_customer,
-- idr_account, idr_household, and idr_household_member.
-- 7-year retention enforced by partition policy.
-- No PII in this table — delta stored as JSON of token/opaque fields.
-- ----------------------------------------------------------------

CREATE TABLE idr_entity_audit_log (
    audit_id            UUID            NOT NULL DEFAULT gen_random_uuid(),
    -- What changed
    entity_type         VARCHAR(64)     NOT NULL,   -- 'idr_customer' | 'idr_account' | 'idr_household'
    entity_id           UUID            NOT NULL,   -- PK of the changed row
    fi_id               VARCHAR(64)     NOT NULL,
    event_type          VARCHAR(64)     NOT NULL,   -- CREATE | UPDATE | MERGE | STUB_CREATED |
                                                    -- HOUSEHOLD_CREATED | MEMBER_ADDED | MEMBER_REMOVED |
                                                    -- HOUSEHOLD_DISSOLVED | GLOBAL_LINK_CREATED
    -- Delta (no PII — JSON of non-PII fields only, or token-only diffs)
    old_values          JSONB           NULL,
    new_values          JSONB           NOT NULL,
    -- Who/what caused the change
    actor               VARCHAR(128)    NOT NULL,   -- service account or 'analyst:<user>'
    correlation_id      UUID            NOT NULL,   -- matches OpenTelemetry trace_id (S-08-01)
    source_event_id     UUID            NULL,       -- triggering payment event_id (if applicable)
    -- Resolution metadata at time of change
    resolution_method   resolution_method NULL,
    confidence_score    NUMERIC(4,3)    NULL,
    -- Partition key
    changed_at          TIMESTAMPTZ     NOT NULL DEFAULT now(),
    PRIMARY KEY (audit_id, changed_at)
)
PARTITION BY RANGE (changed_at);

-- Annual partitions — 7 years forward-provisioned; add annually
CREATE TABLE idr_entity_audit_log_2026 PARTITION OF idr_entity_audit_log FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');
CREATE TABLE idr_entity_audit_log_2027 PARTITION OF idr_entity_audit_log FOR VALUES FROM ('2027-01-01') TO ('2028-01-01');
CREATE TABLE idr_entity_audit_log_2028 PARTITION OF idr_entity_audit_log FOR VALUES FROM ('2028-01-01') TO ('2029-01-01');
CREATE TABLE idr_entity_audit_log_2029 PARTITION OF idr_entity_audit_log FOR VALUES FROM ('2029-01-01') TO ('2030-01-01');
CREATE TABLE idr_entity_audit_log_2030 PARTITION OF idr_entity_audit_log FOR VALUES FROM ('2030-01-01') TO ('2031-01-01');
CREATE TABLE idr_entity_audit_log_2031 PARTITION OF idr_entity_audit_log FOR VALUES FROM ('2031-01-01') TO ('2032-01-01');
CREATE TABLE idr_entity_audit_log_2032 PARTITION OF idr_entity_audit_log FOR VALUES FROM ('2032-01-01') TO ('2033-01-01');

-- Enforce append-only (S-08-03 AC: no UPDATE or DELETE permitted)
CREATE RULE idr_entity_audit_log_no_update AS ON UPDATE TO idr_entity_audit_log DO INSTEAD NOTHING;
CREATE RULE idr_entity_audit_log_no_delete AS ON DELETE TO idr_entity_audit_log DO INSTEAD NOTHING;

CREATE INDEX idx_eal_entity       ON idr_entity_audit_log (entity_id, changed_at);
CREATE INDEX idx_eal_fi_date      ON idr_entity_audit_log (fi_id, changed_at);
CREATE INDEX idx_eal_correlation  ON idr_entity_audit_log (correlation_id);
CREATE INDEX idx_eal_event_type   ON idr_entity_audit_log (event_type, changed_at);

-- ----------------------------------------------------------------
-- RESOLUTION PIPELINE METRICS SNAPSHOT  (S-08-02)
-- Summary rows written by the metrics aggregation job every minute.
-- Source of truth for Grafana dashboard SLO tracking.
-- (Raw counters emitted to Prometheus / OTEL; this is the durable
--  historical record for trend analysis and alerting evaluation.)
-- ----------------------------------------------------------------

CREATE TABLE idr_pipeline_metrics_snapshot (
    snapshot_id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    fi_id               VARCHAR(64) NULL,   -- NULL = platform-wide aggregate
    snapshot_minute     TIMESTAMPTZ NOT NULL,   -- truncated to minute
    -- Throughput
    events_processed    BIGINT      NOT NULL DEFAULT 0,
    events_per_second   NUMERIC(8,2) NOT NULL DEFAULT 0,
    -- Tier distribution (counts this minute)
    tier1_count         BIGINT      NOT NULL DEFAULT 0,
    tier2_count         BIGINT      NOT NULL DEFAULT 0,
    tier3_count         BIGINT      NOT NULL DEFAULT 0,
    tier4_count         BIGINT      NOT NULL DEFAULT 0,
    tier5_count         BIGINT      NOT NULL DEFAULT 0,
    -- Latency percentiles (milliseconds)
    pipeline_p50_ms     NUMERIC(8,2) NULL,
    pipeline_p95_ms     NUMERIC(8,2) NULL,
    pipeline_p99_ms     NUMERIC(8,2) NULL,   -- SLO: < 500ms
    redis_lookup_p99_ms NUMERIC(8,2) NULL,   -- target: < 5ms (S-03-07)
    entity_write_p99_ms NUMERIC(8,2) NULL,
    query_api_p99_ms    NUMERIC(8,2) NULL,   -- SLO: < 200ms (S-05-04)
    -- Queue health
    review_queue_pending    BIGINT  NOT NULL DEFAULT 0,
    kafka_consumer_lag_max  BIGINT  NULL,
    -- DLQ
    dlq_events_this_minute  BIGINT  NOT NULL DEFAULT 0,
    CONSTRAINT uq_snapshot_fi_minute UNIQUE (fi_id, snapshot_minute)
);

CREATE INDEX idx_metrics_fi_time ON idr_pipeline_metrics_snapshot (fi_id, snapshot_minute DESC);

-- ----------------------------------------------------------------
-- SLO BREACH LOG
-- Written whenever an SLO threshold is crossed (S-08-02 ACs).
-- Used to trigger PagerDuty/on-call alerts.
-- ----------------------------------------------------------------

CREATE TYPE slo_metric AS ENUM (
    'PIPELINE_P99_LATENCY',     -- threshold: 500ms
    'QUERY_API_P99_LATENCY',    -- threshold: 200ms
    'REDIS_LOOKUP_P99_LATENCY', -- threshold: 5ms
    'TIER5_UNRESOLVED_RATE',    -- threshold: 30% over 1-hour window
    'KAFKA_CONSUMER_LAG',       -- threshold: 10k messages
    'REVIEW_QUEUE_SLA'          -- threshold: item pending > 5 business days
);

CREATE TABLE idr_slo_breach_log (
    breach_id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    fi_id               VARCHAR(64) NULL,
    slo_metric          slo_metric  NOT NULL,
    threshold_value     NUMERIC     NOT NULL,
    observed_value      NUMERIC     NOT NULL,
    breach_started_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    breach_resolved_at  TIMESTAMPTZ NULL,
    alert_sent          BOOLEAN     NOT NULL DEFAULT FALSE,
    alert_sent_at       TIMESTAMPTZ NULL
);

CREATE INDEX idx_slo_breach_active  ON idr_slo_breach_log (slo_metric, breach_started_at)
    WHERE breach_resolved_at IS NULL;

-- ----------------------------------------------------------------
-- LOAD TEST RUN REGISTRY  (S-08-05)
-- Tracks load test executions and their results for sign-off.
-- ----------------------------------------------------------------

CREATE TABLE idr_load_test_run (
    run_id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    run_label           VARCHAR(128) NOT NULL,   -- e.g. 'pre-prod-10k-30min-2026-03'
    target_events_pm    INTEGER     NOT NULL,    -- events per minute target (e.g. 10000)
    duration_minutes    INTEGER     NOT NULL,    -- e.g. 30
    -- Results
    status              VARCHAR(32) NOT NULL DEFAULT 'RUNNING'
                            CHECK (status IN ('RUNNING', 'PASSED', 'FAILED', 'ABORTED')),
    actual_events_pm    NUMERIC(10,2) NULL,
    p99_pipeline_ms     NUMERIC(8,2) NULL,       -- must be < 500ms to PASS
    data_integrity_ok   BOOLEAN     NULL,        -- post-run validation (S-08-05 AC)
    -- Infrastructure metrics during run
    redis_p99_ms        NUMERIC(8,2) NULL,
    pg_write_p99_ms     NUMERIC(8,2) NULL,
    bottleneck_notes    TEXT        NULL,
    -- Lifecycle
    started_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at        TIMESTAMPTZ NULL,
    initiated_by        VARCHAR(128) NOT NULL
);

-- ----------------------------------------------------------------
-- FI CONFIGURATION TABLE
-- Centralizes per-FI feature flags (household opt-in, probability
-- threshold, API rate limits, etc.).  Used for optional features such
-- as household formation and probabilistic scorer settings.
-- ----------------------------------------------------------------

CREATE TABLE idr_fi_config (
    fi_id                       VARCHAR(64)     PRIMARY KEY,
    -- Household formation (optional, deferred)
    household_joint_account     BOOLEAN         NOT NULL DEFAULT TRUE,
    household_address_match     BOOLEAN         NOT NULL DEFAULT FALSE,  -- opt-in required
    -- Probabilistic scorer (optional, deferred)
    prob_auto_merge_threshold   NUMERIC(4,3)    NOT NULL DEFAULT 0.90
                                    CHECK (prob_auto_merge_threshold BETWEEN 0.70 AND 0.99),
    prob_scorer_enabled         BOOLEAN         NOT NULL DEFAULT FALSE,
    -- Rate limiting (S-05-04)
    api_rate_limit_rpm          INTEGER         NOT NULL DEFAULT 1000,
    -- Lifecycle
    created_at                  TIMESTAMPTZ     NOT NULL DEFAULT now(),
    updated_at                  TIMESTAMPTZ     NOT NULL DEFAULT now(),
    updated_by                  VARCHAR(128)    NULL
);

-- Audit config changes (actor, old value, new value) via trigger or application layer
