-- ============================================================
-- EP-02: PII Vault & Tokenization Service
-- Stories: S-02-01 through S-02-05
-- Design ref: §4.3 Tokenization, §7 Privacy & Compliance
-- ============================================================
-- PostgreSQL (Flyway migration: V2__pii_vault.sql)
-- Note: Actual key material lives in HashiCorp Vault.
--       These tables track token metadata and audit records only.
--       No plaintext PII is ever stored in any of these tables.
-- ============================================================

-- ----------------------------------------------------------------
-- TOKEN REGISTRY
-- Tracks every issued token: type, scope, key version.
-- Enables re-tokenization during key rotation (S-02-05).
-- ----------------------------------------------------------------

CREATE TYPE token_type AS ENUM (
    'FPE_ACCOUNT',      -- FF3-1 format-preserving encryption (S-02-01)
    'SSN_HASH_FI',      -- SHA-256(SSN + platform_salt + fi_id) — per-FI (S-02-02)
    'SSN_HASH_GLOBAL',  -- SHA-256(SSN + platform_salt) — cross-FI (S-02-02)
    'EIN_HASH_FI',      -- same algorithm as SSN_HASH_FI but for EIN (S-15-02)
    'EIN_HASH_GLOBAL',
    'EMAIL_HMAC',       -- HMAC-SHA256(normalize(email), fi_hmac_key) (S-02-03)
    'PHONE_HMAC',       -- HMAC-SHA256(E.164(phone), fi_hmac_key)     (S-02-03)
    'IBAN_FPE',         -- FPE(IBAN) for BK-7 international wires (S-12-02)
    'PAN_FPE'           -- FPE(PAN) for BK-8 card-present (S-16-03)
);

CREATE TABLE idr_token_registry (
    token_id            UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    fi_id               VARCHAR(64)     NOT NULL,
    token_type          token_type      NOT NULL,
    -- The token value itself (no PII — this is the output of tokenization)
    token_value         VARCHAR(255)    NOT NULL,
    -- Key management metadata (actual keys in Vault)
    vault_key_path      VARCHAR(512)    NOT NULL,   -- e.g. secret/idr/fpe/v3
    key_version         SMALLINT        NOT NULL DEFAULT 1,
    -- Rotation state
    is_current          BOOLEAN         NOT NULL DEFAULT TRUE,
    superseded_by       UUID            NULL REFERENCES idr_token_registry (token_id),
    -- Lifecycle
    issued_at           TIMESTAMPTZ     NOT NULL DEFAULT now(),
    rotated_at          TIMESTAMPTZ     NULL,
    -- Correlation back to the entity that owns this token
    idr_customer_id     UUID            NULL,   -- FK to idr_customer (soft ref, no constraint across tenants)
    idr_account_id      UUID            NULL,
    -- Anti-duplication: same source produces same token deterministically
    CONSTRAINT uq_token_current UNIQUE (fi_id, token_type, token_value, key_version)
);

CREATE INDEX idx_token_registry_customer ON idr_token_registry (idr_customer_id) WHERE is_current;
CREATE INDEX idx_token_registry_fi_type  ON idr_token_registry (fi_id, token_type, is_current);
CREATE INDEX idx_token_registry_vault    ON idr_token_registry (vault_key_path, key_version);

-- ----------------------------------------------------------------
-- TOKENIZATION AUDIT LOG  (S-02-04)
-- Append-only. No PII. Queryable by correlation_id and fi_id.
-- 7-year retention enforced at the storage/partition level.
-- ----------------------------------------------------------------

CREATE TYPE tokenization_operation AS ENUM (
    'TOKENIZE',
    'DETOKENIZE',       -- restricted to authorized JHBI service accounts only
    'ROTATE',
    'REVOKE'
);

CREATE TABLE idr_tokenization_audit (
    audit_id            UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    correlation_id      UUID            NOT NULL,   -- trace ID from calling service (S-02-04)
    fi_id               VARCHAR(64)     NOT NULL,
    token_type          token_type      NOT NULL,
    operation           tokenization_operation NOT NULL,
    key_version         SMALLINT        NOT NULL,
    vault_key_path      VARCHAR(512)    NOT NULL,
    -- Outcome
    success             BOOLEAN         NOT NULL,
    failure_reason      VARCHAR(512)    NULL,
    -- Who/what called the service
    calling_service     VARCHAR(128)    NOT NULL,   -- e.g. 'ach-adapter', 'resolution-engine'
    calling_principal   VARCHAR(128)    NOT NULL,   -- Vault AppRole or k8s service account name
    -- When (partition key for retention management)
    operation_timestamp TIMESTAMPTZ     NOT NULL DEFAULT now()
)
PARTITION BY RANGE (operation_timestamp);

-- Annual partitions; DBA creates new partition each December for the following year
-- Example:
CREATE TABLE idr_tokenization_audit_2026
    PARTITION OF idr_tokenization_audit
    FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');

CREATE TABLE idr_tokenization_audit_2027
    PARTITION OF idr_tokenization_audit
    FOR VALUES FROM ('2027-01-01') TO ('2028-01-01');

CREATE INDEX idx_tok_audit_correlation ON idr_tokenization_audit (correlation_id);
CREATE INDEX idx_tok_audit_fi_date     ON idr_tokenization_audit (fi_id, operation_timestamp);

-- ----------------------------------------------------------------
-- KEY ROTATION JOB STATE  (S-02-05)
-- Tracks progress of background FPE re-tokenization jobs.
-- ----------------------------------------------------------------

CREATE TYPE rotation_job_status AS ENUM (
    'PENDING',
    'RUNNING',
    'COMPLETED',
    'FAILED',
    'ROLLED_BACK'
);

CREATE TABLE idr_key_rotation_job (
    job_id              UUID                PRIMARY KEY DEFAULT gen_random_uuid(),
    fi_id               VARCHAR(64)         NULL,       -- NULL = platform-wide rotation
    token_type          token_type          NOT NULL,
    old_key_version     SMALLINT            NOT NULL,
    new_key_version     SMALLINT            NOT NULL,
    vault_key_path      VARCHAR(512)        NOT NULL,
    status              rotation_job_status NOT NULL DEFAULT 'PENDING',
    total_tokens        BIGINT              NULL,
    tokens_processed    BIGINT              NOT NULL DEFAULT 0,
    tokens_failed       BIGINT              NOT NULL DEFAULT 0,
    started_at          TIMESTAMPTZ         NULL,
    completed_at        TIMESTAMPTZ         NULL,
    initiated_by        VARCHAR(128)        NOT NULL,
    notes               TEXT                NULL
);

CREATE INDEX idx_rotation_job_status ON idr_key_rotation_job (status, token_type);

-- ----------------------------------------------------------------
-- DETOKENIZATION ACCESS CONTROL  (S-02-01 AC)
-- Which service principals are permitted to call DETOKENIZE.
-- Authoritative list; enforced by the tokenization service.
-- ----------------------------------------------------------------

CREATE TABLE idr_detokenize_allowlist (
    principal_name      VARCHAR(128)    PRIMARY KEY,
    token_types_allowed token_type[]    NOT NULL,   -- which token types they can detokenize
    fi_id_restriction   VARCHAR(64)     NULL,       -- NULL = unrestricted (JHBI internal only)
    granted_by          VARCHAR(128)    NOT NULL,
    granted_at          TIMESTAMPTZ     NOT NULL DEFAULT now(),
    revoked_at          TIMESTAMPTZ     NULL,
    CONSTRAINT chk_detokenize_not_revoked CHECK (revoked_at IS NULL OR revoked_at > granted_at)
);
