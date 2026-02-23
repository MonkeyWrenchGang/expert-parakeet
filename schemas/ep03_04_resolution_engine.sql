-- ============================================================
-- EP-03: Blocking Key Derivation Service
-- EP-04: Resolution Engine Core
-- Stories: S-03-01 through S-03-06, S-04-01 through S-04-06
-- Design ref: §5 Blocking & Bucketing, BK-1–BK-8, §3 Silver Layer
-- ============================================================
-- PostgreSQL (Flyway migration: V3__resolution_engine.sql)
--
-- NOTE: The Redis inverted index (BK_TYPE:{hash} → set<idr_customer_id>)
--       is managed at runtime by the Blocking Key Derivation Service.
--       The tables below are the durable PostgreSQL side: decision log,
--       review queue, and blocking key metadata.
-- ============================================================

-- ----------------------------------------------------------------
-- BLOCKING KEY CATALOG
-- Reference table enumerating all 8 BKs, their tier contribution,
-- and whether they may be used as a sole blocking key.
-- ----------------------------------------------------------------

CREATE TABLE idr_blocking_key_def (
    bk_code             VARCHAR(8)      PRIMARY KEY,    -- 'BK1' … 'BK8'
    bk_name             VARCHAR(128)    NOT NULL,
    description         TEXT            NOT NULL,
    min_tier_solo       SMALLINT        NOT NULL,   -- lowest tier achievable when matched alone
    can_be_sole_key     BOOLEAN         NOT NULL,   -- BK-6 = FALSE (S-03-05)
    pii_class           VARCHAR(64)     NOT NULL,   -- e.g. 'SSN','ACCOUNT','EMAIL','PHONE'
    is_cross_fi         BOOLEAN         NOT NULL DEFAULT FALSE,
    notes               TEXT            NULL
);

INSERT INTO idr_blocking_key_def VALUES
-- bk_code, bk_name,                             description,                                              min_tier_solo, can_be_sole_key, pii_class,       is_cross_fi
('BK1', 'SSN/TIN (plaintext)',                  'Normalized plaintext SSN/EIN (digits only); exact match within FI',  1,   TRUE,  'SSN',            FALSE),
('BK2', 'Account + Routing',                    'Plaintext account number : routing number (public)',      2,   TRUE,  'ACCOUNT',        FALSE),
('BK3', 'Email (normalized)',                   'Plaintext email normalized to lowercase; sub-addressing stripped',    3,   TRUE,  'EMAIL',          FALSE),
('BK4', 'Phone / Zelle',                        'Plaintext phone in E.164 format; Zelle proxies classified as phone or email', 3,   TRUE,  'PHONE',          FALSE),
('BK5', 'Core CIF / Source ID',                 'source_system : source_customer_id from originating system',          2,   TRUE,  'SOURCE_ID',      FALSE),
('BK6', 'Name + Zip5 (secondary only)',         'Uppercase name (stripped punctuation) : zip5; secondary signal only', 4,   FALSE, 'NAME_ZIP',       FALSE),
('BK7', 'SWIFT BIC + IBAN (intl wires)',        'SWIFT BIC validated : plaintext IBAN or account number',  4,   TRUE,  'WIRE',           FALSE),
('BK8', 'PAN (card-present)',                   'Card network token or plaintext PAN; Tier 5 MINIMAL_STUB only',      5,   TRUE,  'PAN',            FALSE);

-- ----------------------------------------------------------------
-- RESOLUTION TIER DEFINITION
-- Authoritative tier → confidence band mapping (S-04-02)
-- ----------------------------------------------------------------

CREATE TABLE idr_resolution_tier_def (
    tier                SMALLINT        PRIMARY KEY CHECK (tier BETWEEN 1 AND 5),
    tier_label          VARCHAR(32)     NOT NULL,
    confidence_min      NUMERIC(4,3)    NOT NULL,
    confidence_max      NUMERIC(4,3)    NOT NULL,
    auto_merge          BOOLEAN         NOT NULL,
    creates_stub        BOOLEAN         NOT NULL,
    qualifying_bks      VARCHAR(8)[]    NOT NULL,
    notes               TEXT            NULL
);

INSERT INTO idr_resolution_tier_def VALUES
(1, 'DEFINITIVE', 1.000, 1.000, TRUE,  FALSE, ARRAY['BK1'],             'SSN/EIN exact match within FI'),
(2, 'HIGH',       0.900, 0.999, TRUE,  FALSE, ARRAY['BK2','BK5'],       'Account token or core CIF match'),
(3, 'VERIFIED',   0.850, 0.920, TRUE,  FALSE, ARRAY['BK3','BK4'],       'Email or phone proxy match; conflicts route to review'),
(4, 'INFERRED',   0.650, 0.840, FALSE, TRUE,  ARRAY['BK6','BK7'],       'Name+zip secondary or intl wire BIC/IBAN; EXTERNAL_STUB'),
(5, 'UNRESOLVED', 0.000, 0.649, FALSE, TRUE,  ARRAY['BK8'],             'Card-present only; MINIMAL_STUB, never auto-merge');

-- ----------------------------------------------------------------
-- MATCH DECISION LOG  (S-04-06)
-- Immutable. Append-only. Partitioned by month (3-year retention).
-- Serves as the authoritative audit trail and analytics corpus.
-- ----------------------------------------------------------------

CREATE TYPE resolution_action AS ENUM (
    'MERGE',
    'STUB_EXTERNAL',
    'STUB_MINIMAL',
    'ROUTE_TO_REVIEW',
    'IDEMPOTENT_SKIP'   -- event_id already processed; no-op
);

CREATE TABLE idr_match_decision_log (
    decision_id         UUID            NOT NULL DEFAULT gen_random_uuid(),
    -- Event that triggered the resolution
    event_id            UUID            NOT NULL,
    fi_id               VARCHAR(64)     NOT NULL,
    source_product      VARCHAR(64)     NULL,   -- e.g. 'silverlake', 'ach_eps', 'payrailz_p2p'
    -- Resolution outcome
    idr_customer_id     UUID            NULL,   -- resolved entity (NULL for new stubs)
    matched_bks         VARCHAR(8)[]    NOT NULL DEFAULT '{}',
    tier                SMALLINT        NOT NULL REFERENCES idr_resolution_tier_def (tier),
    confidence_score    NUMERIC(4,3)    NOT NULL,
    action              resolution_action NOT NULL,
    -- Model metadata (NULL for deterministic path)
    model_version       VARCHAR(64)     NULL,
    model_score         NUMERIC(6,5)    NULL,
    -- Audit
    decision_timestamp  TIMESTAMPTZ     NOT NULL DEFAULT now(),
    pipeline_trace_id   UUID            NULL,   -- OpenTelemetry trace correlation (S-08-01)
    PRIMARY KEY (decision_id, decision_timestamp)
)
PARTITION BY RANGE (decision_timestamp);

-- Monthly partitions (3 years forward-provisioned; add annually)
CREATE TABLE idr_match_decision_log_2026_01 PARTITION OF idr_match_decision_log FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE idr_match_decision_log_2026_02 PARTITION OF idr_match_decision_log FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
CREATE TABLE idr_match_decision_log_2026_03 PARTITION OF idr_match_decision_log FOR VALUES FROM ('2026-03-01') TO ('2026-04-01');
CREATE TABLE idr_match_decision_log_2026_04 PARTITION OF idr_match_decision_log FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');
CREATE TABLE idr_match_decision_log_2026_05 PARTITION OF idr_match_decision_log FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE idr_match_decision_log_2026_06 PARTITION OF idr_match_decision_log FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');
CREATE TABLE idr_match_decision_log_2026_07 PARTITION OF idr_match_decision_log FOR VALUES FROM ('2026-07-01') TO ('2026-08-01');
CREATE TABLE idr_match_decision_log_2026_08 PARTITION OF idr_match_decision_log FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');
CREATE TABLE idr_match_decision_log_2026_09 PARTITION OF idr_match_decision_log FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');
CREATE TABLE idr_match_decision_log_2026_10 PARTITION OF idr_match_decision_log FOR VALUES FROM ('2026-10-01') TO ('2026-11-01');
CREATE TABLE idr_match_decision_log_2026_11 PARTITION OF idr_match_decision_log FOR VALUES FROM ('2026-11-01') TO ('2026-12-01');
CREATE TABLE idr_match_decision_log_2026_12 PARTITION OF idr_match_decision_log FOR VALUES FROM ('2026-12-01') TO ('2027-01-01');

CREATE INDEX idx_mdl_event_id   ON idr_match_decision_log (event_id);
CREATE INDEX idx_mdl_fi_tier    ON idr_match_decision_log (fi_id, tier, decision_timestamp);
CREATE INDEX idx_mdl_customer   ON idr_match_decision_log (idr_customer_id) WHERE idr_customer_id IS NOT NULL;
CREATE INDEX idx_mdl_action     ON idr_match_decision_log (action, decision_timestamp);

-- Enforce append-only (no updates/deletes) via rule
CREATE RULE idr_match_decision_log_no_update AS ON UPDATE TO idr_match_decision_log DO INSTEAD NOTHING;
CREATE RULE idr_match_decision_log_no_delete AS ON DELETE TO idr_match_decision_log DO INSTEAD NOTHING;

-- ----------------------------------------------------------------
-- MANUAL REVIEW QUEUE  (S-03-05)
-- Tier-3 conflicts that need analyst resolution.
-- ----------------------------------------------------------------

CREATE TYPE review_status AS ENUM (
    'PENDING',
    'IN_REVIEW',
    'RESOLVED_MERGE',
    'RESOLVED_REJECT',
    'EXPIRED'
);

CREATE TABLE idr_review_queue (
    review_id               UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    fi_id                   VARCHAR(64)     NOT NULL,
    -- Triggering event
    event_id                UUID            NOT NULL,
    source_product          VARCHAR(64)     NULL,
    -- Candidates in conflict
    candidate_entity_ids    UUID[]          NOT NULL,
    matched_bks             VARCHAR(8)[]    NOT NULL,
    conflict_reason         VARCHAR(512)    NOT NULL,
    tier                    SMALLINT        NOT NULL,
    confidence_score        NUMERIC(4,3)    NOT NULL,
    -- Queue management
    status                  review_status   NOT NULL DEFAULT 'PENDING',
    assigned_to             VARCHAR(128)    NULL,
    -- Resolution
    resolved_entity_id      UUID            NULL,   -- entity kept after merge/reject decision
    resolution_notes        TEXT            NULL,
    resolved_by             VARCHAR(128)    NULL,
    -- Timestamps
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT now(),
    assigned_at             TIMESTAMPTZ     NULL,
    resolved_at             TIMESTAMPTZ     NULL,
    sla_deadline            TIMESTAMPTZ     GENERATED ALWAYS AS
                                (created_at + INTERVAL '5 business days') STORED,
    -- Idempotency
    CONSTRAINT uq_review_event UNIQUE (fi_id, event_id)
);

ALTER TABLE idr_review_queue ENABLE ROW LEVEL SECURITY;
CREATE POLICY idr_review_queue_fi_isolation ON idr_review_queue
    USING (fi_id = current_setting('app.fi_id', true));

CREATE INDEX idx_review_queue_status    ON idr_review_queue (fi_id, status, created_at);
CREATE INDEX idx_review_queue_sla       ON idr_review_queue (sla_deadline) WHERE status = 'PENDING';
CREATE INDEX idx_review_queue_assigned  ON idr_review_queue (assigned_to)  WHERE status = 'IN_REVIEW';

-- ----------------------------------------------------------------
-- IDEMPOTENCY LEDGER
-- Prevents duplicate resolution when the same event is replayed
-- (Kafka at-least-once delivery; S-03-03 AC: merge is idempotent).
-- ----------------------------------------------------------------

CREATE TABLE idr_event_idempotency (
    event_id            UUID            PRIMARY KEY,
    fi_id               VARCHAR(64)     NOT NULL,
    processed_at        TIMESTAMPTZ     NOT NULL DEFAULT now(),
    decision_id         UUID            NOT NULL,   -- FK to match_decision_log
    action              resolution_action NOT NULL
);

CREATE INDEX idx_idempotency_fi ON idr_event_idempotency (fi_id, processed_at);

-- ----------------------------------------------------------------
-- PHASE 3: SHADOW PIPELINE DECISIONS  (S-17-05)
-- Probabilistic model predictions run in parallel with deterministic.
-- ----------------------------------------------------------------

CREATE TABLE idr_shadow_decisions (
    shadow_id           UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id            UUID            NOT NULL,
    fi_id               VARCHAR(64)     NOT NULL,
    -- Deterministic outcome (from idr_match_decision_log)
    det_tier            SMALLINT        NOT NULL,
    det_action          resolution_action NOT NULL,
    det_confidence      NUMERIC(4,3)    NOT NULL,
    -- Probabilistic model prediction
    prob_score          NUMERIC(6,5)    NOT NULL,
    prob_action         resolution_action NOT NULL,
    model_version       VARCHAR(64)     NOT NULL,
    -- Agreement flag (populated by daily batch)
    decisions_agree     BOOLEAN         GENERATED ALWAYS AS (det_action = prob_action) STORED,
    -- Timing
    evaluated_at        TIMESTAMPTZ     NOT NULL DEFAULT now()
);

CREATE INDEX idx_shadow_fi_agree    ON idr_shadow_decisions (fi_id, decisions_agree, evaluated_at);
CREATE INDEX idx_shadow_model_ver   ON idr_shadow_decisions (model_version, evaluated_at);

-- ----------------------------------------------------------------
-- PHASE 3: ML TRAINING FEATURES  (S-17-02)
-- Feature vectors extracted from match_decision_log pairs.
-- ----------------------------------------------------------------

CREATE TABLE idr_training_features (
    feature_id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    decision_id             UUID            NOT NULL,   -- FK to idr_match_decision_log
    fi_id                   VARCHAR(64)     NOT NULL,
    -- Feature values
    name_jaro_winkler       NUMERIC(5,4)    NULL,
    address_jaccard         NUMERIC(5,4)    NULL,
    dob_match_flag          NUMERIC(3,1)    NULL,   -- 1.0 = exact, 0.5 = year-only, 0.0 = no match
    bk_match_count          SMALLINT        NOT NULL DEFAULT 0,
    entity_type_agreement   BOOLEAN         NULL,
    transaction_freq_overlap NUMERIC(5,4)  NULL,
    -- Label
    label                   SMALLINT        NOT NULL CHECK (label IN (0, 1)),
    -- 1 = positive (MERGE / REVIEW_ACCEPTED), 0 = negative (STUB / REVIEW_REJECTED)
    -- Temporal guard: prevent future leakage (S-17-01)
    decision_date           DATE            NOT NULL,
    extracted_at            TIMESTAMPTZ     NOT NULL DEFAULT now()
);

CREATE INDEX idx_train_features_fi_date ON idr_training_features (fi_id, decision_date);
CREATE INDEX idx_train_features_label   ON idr_training_features (label, decision_date);
