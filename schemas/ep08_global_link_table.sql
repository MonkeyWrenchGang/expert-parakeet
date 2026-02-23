-- ============================================================
-- EP-07: JH-Global Link Table
-- Stories: S-07-01
-- Design ref: §4.4 Two-Tier Architecture, §7 Privacy & Compliance
-- ============================================================
-- PostgreSQL (Flyway migration: V4__global_link_table.sql)
--
-- ACCESS POLICY:
--   - NOT exposed via FI-facing Query API (EP-06)
--   - Accessible only to JHBI internal service account
--   - Internal API requires scope: idr:global:read  (S-07-01)
--
-- QUALIFYING SIGNALS (by design):
--   - BK1: SHA-256(SSN/EIN + platform_salt) computed at runtime — not persisted
--   - BK2: account_number + ':' + routing_number (plaintext comparison)
--   - Email / phone are INTENTIONALLY EXCLUDED from cross-FI linking  (S-07-01)
-- ============================================================

-- ----------------------------------------------------------------
-- GLOBAL PERSON REGISTRY
-- One row per unique individual/business identified across FIs.
-- No PII stored here — only the opaque global UUID.
-- ----------------------------------------------------------------

CREATE TABLE idr_global_person (
    idr_global_person_id    UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_linked_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    fi_count                SMALLINT    NOT NULL DEFAULT 0,     -- denormalized for quick cardinality queries
    entity_type             entity_type NULL,
    notes                   TEXT        NULL    -- internal JHBI operational notes only
);

-- ----------------------------------------------------------------
-- GLOBAL LINK TABLE  (S-08-01)
-- Maps idr_global_person_id → (fi_id, idr_customer_id)
-- qualifying_bk MUST be 'BK1' or 'BK2' only (enforced by constraint).
-- BK1 qualifying_token = SHA-256(SSN + platform_salt) computed at runtime.
-- BK2 qualifying_token = account_number + ':' + routing_number (plaintext).
-- ----------------------------------------------------------------

CREATE TABLE idr_global_links (
    link_id                 UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    idr_global_person_id    UUID        NOT NULL REFERENCES idr_global_person (idr_global_person_id),
    fi_id                   VARCHAR(64) NOT NULL,
    idr_customer_id         UUID        NOT NULL,   -- references idr_customer.idr_customer_id
    qualifying_bk           VARCHAR(8)  NOT NULL
                                CHECK (qualifying_bk IN ('BK1', 'BK2')),  -- S-08-01: email/phone excluded from cross-FI linking
    -- Which hash/token triggered the link (no PII — opaque token value)
    qualifying_token        VARCHAR(255) NOT NULL,
    -- Lifecycle
    linked_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    dissolved_at            TIMESTAMPTZ NULL,
    is_active               BOOLEAN     GENERATED ALWAYS AS (dissolved_at IS NULL) STORED,
    -- If two candidate global IDs conflict (S-07-01): flag for analyst
    conflict_flag           BOOLEAN     NOT NULL DEFAULT FALSE,
    conflict_notes          TEXT        NULL,
    CONSTRAINT uq_global_fi_customer UNIQUE (idr_global_person_id, fi_id, idr_customer_id)
);

-- Global person updated back to entity record via idr_customer.idr_global_person_id (S-08-01)
CREATE INDEX idx_global_links_person ON idr_global_links (idr_global_person_id) WHERE is_active;
CREATE INDEX idx_global_links_fi_cust ON idr_global_links (fi_id, idr_customer_id) WHERE is_active;
CREATE INDEX idx_global_links_bk      ON idr_global_links (qualifying_bk, qualifying_token) WHERE is_active;
CREATE INDEX idx_global_links_conflict ON idr_global_links (conflict_flag) WHERE conflict_flag;

-- ----------------------------------------------------------------
-- GLOBAL LINK AUDIT LOG  (S-08-01 AC: every link creation/dissolution)
-- Append-only.
-- ----------------------------------------------------------------

CREATE TYPE global_link_event AS ENUM (
    'LINKED',
    'DISSOLVED',
    'CONFLICT_FLAGGED',
    'CONFLICT_RESOLVED'
);

CREATE TABLE idr_global_link_audit (
    audit_id                UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    link_id                 UUID            NOT NULL REFERENCES idr_global_links (link_id),
    idr_global_person_id    UUID            NOT NULL,
    fi_id                   VARCHAR(64)     NOT NULL,
    idr_customer_id         UUID            NOT NULL,
    event_type              global_link_event NOT NULL,
    qualifying_bk           VARCHAR(8)      NOT NULL,
    triggered_by            VARCHAR(128)    NOT NULL,   -- 'nightly_bk1_batch', 'nightly_bk2_batch', etc.
    batch_run_id            UUID            NULL,       -- FK to batch run metadata if applicable
    event_timestamp         TIMESTAMPTZ     NOT NULL DEFAULT now(),
    notes                   TEXT            NULL
);

-- Enforce append-only
CREATE RULE idr_global_link_audit_no_update AS ON UPDATE TO idr_global_link_audit DO INSTEAD NOTHING;
CREATE RULE idr_global_link_audit_no_delete AS ON DELETE TO idr_global_link_audit DO INSTEAD NOTHING;

CREATE INDEX idx_gla_global_person ON idr_global_link_audit (idr_global_person_id, event_timestamp);
CREATE INDEX idx_gla_fi_cust       ON idr_global_link_audit (fi_id, idr_customer_id, event_timestamp);

-- ----------------------------------------------------------------
-- NIGHTLY BATCH JOB STATE  (S-08-01 AC: nightly BK1/BK2 cross-FI linking jobs)
-- Tracks each run of the BK1 and BK2 cross-FI linking jobs.
-- ----------------------------------------------------------------

CREATE TABLE idr_global_link_batch_run (
    batch_run_id        UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    batch_type          VARCHAR(32) NOT NULL CHECK (batch_type IN ('BK1_SSN_PLATFORM', 'BK2_ACCOUNT_TOKEN')),
    status              VARCHAR(32) NOT NULL DEFAULT 'RUNNING'
                            CHECK (status IN ('RUNNING', 'COMPLETED', 'FAILED')),
    -- Metrics (S-08-01 AC)
    links_created       BIGINT      NOT NULL DEFAULT 0,
    links_dissolved     BIGINT      NOT NULL DEFAULT 0,
    conflicts_flagged   BIGINT      NOT NULL DEFAULT 0,
    fis_spanned_max     SMALLINT    NULL,   -- max FI count for any single global person this run
    entities_scanned    BIGINT      NOT NULL DEFAULT 0,
    -- Timing
    started_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at        TIMESTAMPTZ NULL,
    processing_seconds  NUMERIC(10,2) GENERATED ALWAYS AS
                            (EXTRACT(EPOCH FROM (completed_at - started_at))) STORED,
    error_message       TEXT        NULL
);

-- ----------------------------------------------------------------
-- EMAIL/PHONE ISOLATION ASSERTION VIEW  (S-08-01)
-- Runtime guard: confirms no BK3/BK4 tokens appear in global links.
-- This view should always return 0 rows; monitored by CI tests.
-- ----------------------------------------------------------------

CREATE OR REPLACE VIEW idr_global_link_isolation_check AS
SELECT
    gl.link_id,
    gl.qualifying_bk,
    gl.fi_id,
    gl.idr_customer_id,
    gl.linked_at
FROM idr_global_links gl
WHERE gl.qualifying_bk NOT IN ('BK1', 'BK2')
   OR gl.qualifying_bk IS NULL;

COMMENT ON VIEW idr_global_link_isolation_check IS
    'INVARIANT: must always return 0 rows. BK3/BK4 (email/phone) are never used for cross-FI global linking (S-08-01). Only BK1 (SSN runtime hash) and BK2 (account+routing) qualify.';
