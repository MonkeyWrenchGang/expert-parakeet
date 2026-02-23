-- ============================================================
-- PCI VAULT & CARD TOKENIZATION  (Optional / Deferred)
-- For card data (PAN) only. NOT required for core identity resolution.
-- Design ref: §7 PCI DSS Compliance
-- ============================================================
-- PostgreSQL (Flyway migration: V2__pci_vault.sql)
--
-- SCOPE: Only PAN (card Primary Account Numbers) are tokenized.
--        PII fields (SSN, email, phone, account numbers, IBAN)
--        are stored in PLAINTEXT in the entity tables.
--        This service exists solely to keep IDR out of PCI DSS
--        scope for card data — not for general PII protection.
--
-- Key material lives in HashiCorp Vault.
-- These tables track PAN token metadata and audit records only.
-- ============================================================

-- ----------------------------------------------------------------
-- TOKEN TYPE ENUM  (PAN only)
-- ----------------------------------------------------------------

CREATE TYPE pci_token_type AS ENUM (
    'PAN_FPE'           -- FF3-1 FPE(PAN) for BK-8 card-present (S-16-03)
                        -- Produces a token identical in length/format to the raw PAN.
                        -- Source: Tap2Local / EPS gateway card-acceptance transactions.
);

-- ----------------------------------------------------------------
-- PAN TOKEN REGISTRY
-- Tracks every issued PAN token: key version, rotation state.
-- One row per unique PAN token. No raw PAN ever stored here.
-- ----------------------------------------------------------------

CREATE TABLE idr_pan_token_registry (
    token_id            UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    fi_id               VARCHAR(64)     NOT NULL,
    token_type          pci_token_type  NOT NULL DEFAULT 'PAN_FPE',
    -- The FPE token value (not the raw PAN)
    pan_token_value     VARCHAR(19)     NOT NULL,   -- same length as a 16-19 digit PAN
    -- Key management metadata (actual FPE key in HashiCorp Vault)
    vault_key_path      VARCHAR(512)    NOT NULL,   -- e.g. secret/idr/pan-fpe/v1
    key_version         SMALLINT        NOT NULL DEFAULT 1,
    -- Rotation state
    is_current          BOOLEAN         NOT NULL DEFAULT TRUE,
    superseded_by       UUID            NULL REFERENCES idr_pan_token_registry (token_id),
    -- Lifecycle
    issued_at           TIMESTAMPTZ     NOT NULL DEFAULT now(),
    rotated_at          TIMESTAMPTZ     NULL,
    -- Correlation back to the stub entity that uses this token
    idr_customer_id     UUID            NULL,   -- soft FK to idr_customer
    -- Card network context (not PAN — these are public/non-sensitive fields)
    card_network        VARCHAR(16)     NULL,   -- VISA, MASTERCARD, AMEX, DISCOVER
    card_last4          VARCHAR(4)      NULL,   -- last 4 digits (non-PCI per PCI DSS §3.3)
    -- Anti-duplication
    CONSTRAINT uq_pan_token_current UNIQUE (fi_id, pan_token_value, key_version)
);

CREATE INDEX idx_pan_token_customer ON idr_pan_token_registry (idr_customer_id) WHERE is_current;
CREATE INDEX idx_pan_token_fi       ON idr_pan_token_registry (fi_id, is_current);
CREATE INDEX idx_pan_token_vault    ON idr_pan_token_registry (vault_key_path, key_version);

-- ----------------------------------------------------------------
-- PAN TOKENIZATION AUDIT LOG
-- Append-only. No PAN stored. Queryable by correlation_id.
-- PCI DSS requirement: log all access to cardholder data.
-- ----------------------------------------------------------------

CREATE TYPE pan_tokenization_operation AS ENUM (
    'TOKENIZE',
    'DETOKENIZE',   -- highly restricted; PCI audit event
    'ROTATE',
    'REVOKE'
);

CREATE TABLE idr_pan_tokenization_audit (
    audit_id            UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    correlation_id      UUID            NOT NULL,
    fi_id               VARCHAR(64)     NOT NULL,
    operation           pan_tokenization_operation NOT NULL,
    key_version         SMALLINT        NOT NULL,
    vault_key_path      VARCHAR(512)    NOT NULL,
    -- Outcome
    success             BOOLEAN         NOT NULL,
    failure_reason      VARCHAR(512)    NULL,
    -- Caller
    calling_service     VARCHAR(128)    NOT NULL,   -- e.g. 'tap2local-adapter', 'eps-card-adapter'
    calling_principal   VARCHAR(128)    NOT NULL,   -- Vault AppRole / k8s service account
    -- When
    operation_timestamp TIMESTAMPTZ     NOT NULL DEFAULT now()
)
PARTITION BY RANGE (operation_timestamp);

CREATE TABLE idr_pan_tokenization_audit_2026
    PARTITION OF idr_pan_tokenization_audit
    FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');

CREATE TABLE idr_pan_tokenization_audit_2027
    PARTITION OF idr_pan_tokenization_audit
    FOR VALUES FROM ('2027-01-01') TO ('2028-01-01');

CREATE INDEX idx_pan_audit_correlation ON idr_pan_tokenization_audit (correlation_id);
CREATE INDEX idx_pan_audit_fi_date     ON idr_pan_tokenization_audit (fi_id, operation_timestamp);

-- Append-only enforcement
CREATE RULE idr_pan_audit_no_update AS ON UPDATE TO idr_pan_tokenization_audit DO INSTEAD NOTHING;
CREATE RULE idr_pan_audit_no_delete AS ON DELETE TO idr_pan_tokenization_audit DO INSTEAD NOTHING;

-- ----------------------------------------------------------------
-- PAN KEY ROTATION JOB
-- ----------------------------------------------------------------

CREATE TABLE idr_pan_key_rotation_job (
    job_id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    old_key_version     SMALLINT        NOT NULL,
    new_key_version     SMALLINT        NOT NULL,
    vault_key_path      VARCHAR(512)    NOT NULL,
    status              VARCHAR(32)     NOT NULL DEFAULT 'PENDING'
                            CHECK (status IN ('PENDING','RUNNING','COMPLETED','FAILED','ROLLED_BACK')),
    total_tokens        BIGINT          NULL,
    tokens_processed    BIGINT          NOT NULL DEFAULT 0,
    tokens_failed       BIGINT          NOT NULL DEFAULT 0,
    started_at          TIMESTAMPTZ     NULL,
    completed_at        TIMESTAMPTZ     NULL,
    initiated_by        VARCHAR(128)    NOT NULL,
    notes               TEXT            NULL
);

-- ----------------------------------------------------------------
-- DETOKENIZATION ALLOWLIST  (PCI DSS: restrict PAN access)
-- ----------------------------------------------------------------

CREATE TABLE idr_pan_detokenize_allowlist (
    principal_name      VARCHAR(128)    PRIMARY KEY,
    fi_id_restriction   VARCHAR(64)     NULL,   -- NULL = JHBI-internal only
    granted_by          VARCHAR(128)    NOT NULL,
    granted_at          TIMESTAMPTZ     NOT NULL DEFAULT now(),
    revoked_at          TIMESTAMPTZ     NULL,
    CONSTRAINT chk_pan_detokenize_not_revoked
        CHECK (revoked_at IS NULL OR revoked_at > granted_at)
);

-- ----------------------------------------------------------------
-- NOTE: What is NOT in this service
-- ----------------------------------------------------------------
-- SSN / TIN      → stored plaintext in idr_customer.ssn (access-controlled via RLS)
-- Account numbers→ stored plaintext in idr_account.account_number (RLS-protected)
-- Email addresses→ stored plaintext in idr_customer.email
-- Phone numbers  → stored plaintext in idr_customer.phone
-- IBAN           → stored plaintext in idr_account.iban (international wires)
-- All PII fields are protected by PostgreSQL Row-Level Security (fi_id scoping)
-- and application-layer OAuth scopes — not by tokenization.
