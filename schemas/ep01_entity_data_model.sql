-- ============================================================
-- EP-01: Entity Data Model & Schema
-- Stories: S-01-01, S-01-02, S-01-03, S-01-04
-- Design ref: §4 Entity Model
-- ============================================================
-- PostgreSQL (Flyway migration: V1__entity_data_model.sql)
--
-- TOKENIZATION POLICY:
--   Only PAN (card Primary Account Numbers) are tokenized via FPE.
--   All other identity fields (SSN, account number, email, phone,
--   IBAN) are stored in PLAINTEXT and protected by:
--     1. PostgreSQL Row-Level Security (fi_id isolation)
--     2. Application-layer OAuth scopes (idr:read:customers etc.)
-- ============================================================

-- ----------------------------------------------------------------
-- ENUMs
-- ----------------------------------------------------------------

CREATE TYPE entity_type AS ENUM (
    'INDIVIDUAL',
    'BUSINESS',
    'UNKNOWN'
);

CREATE TYPE resolution_method AS ENUM (
    'SEEDED',           -- loaded from SilverLake/Symitar baseline
    'DETERMINISTIC',    -- blocking-key match in resolution engine
    'PROBABILISTIC',    -- Phase 3 ML scorer
    'MANUAL_REVIEW'     -- analyst accepted merge from review queue
);

CREATE TYPE profile_completeness AS ENUM (
    'FULL',             -- core-seeded JH member with all identity fields
    'PARTIAL',          -- some identity fields present, not all
    'EXTERNAL',         -- external counterparty (non-JH FI)
    'EXTERNAL_STUB',    -- Tier 4: inferred external entity
    'MINIMAL_STUB',     -- Tier 5: unresolved, minimal signals only
    'BILLER'            -- bill pay biller (entity_type=BUSINESS)
);

CREATE TYPE entity_status AS ENUM (
    'ACTIVE',
    'MERGED',           -- absorbed into another entity
    'DELETED',
    'SUSPENDED'
);

-- ----------------------------------------------------------------
-- ACCOUNT  (one account record per unique account+routing+fi_id)
-- PII stored in plaintext; protected by RLS + OAuth scopes.
-- ----------------------------------------------------------------

CREATE TABLE idr_account (
    idr_account_id          UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    fi_id                   VARCHAR(64)     NOT NULL,   -- FI tenant identifier (RLS key)

    -- Account number stored plaintext (RLS-protected, not tokenized)
    account_number          VARCHAR(64)     NOT NULL,
    routing_number          VARCHAR(9)      NOT NULL,   -- public ABA routing number
    -- Derived blocking key: plaintext concat used directly as BK-2
    bk2_key                 VARCHAR(255)    GENERATED ALWAYS AS (account_number || ':' || routing_number) STORED,

    -- IBAN for international wire accounts (plaintext)
    iban                    VARCHAR(34)     NULL,
    swift_bic               VARCHAR(11)     NULL,

    -- Source linkage
    source_system           VARCHAR(64)     NULL,       -- e.g. 'silverlake', 'symitar'
    source_account_id       VARCHAR(255)    NULL,       -- native account ID in source system

    -- Account metadata
    account_type            VARCHAR(64)     NULL,       -- CHECKING, SAVINGS, LOAN, WIRE_BENEFICIARY, etc.
    is_joint                BOOLEAN         NOT NULL DEFAULT FALSE,
    is_external             BOOLEAN         NOT NULL DEFAULT FALSE,  -- non-JH FI account

    -- Temporal columns (S-01-01)
    valid_from              TIMESTAMPTZ     NOT NULL DEFAULT now(),
    valid_to                TIMESTAMPTZ     NULL,       -- NULL = current record
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT now()
);

-- RLS (S-01-02): FI tenant isolation — no FI can read another FI's accounts
ALTER TABLE idr_account ENABLE ROW LEVEL SECURITY;
CREATE POLICY idr_account_fi_isolation ON idr_account
    USING (fi_id = current_setting('app.fi_id', true));

CREATE INDEX idx_idr_account_bk2   ON idr_account (fi_id, bk2_key) WHERE valid_to IS NULL;
CREATE INDEX idx_idr_account_fi    ON idr_account (fi_id) WHERE valid_to IS NULL;
CREATE INDEX idx_idr_account_iban  ON idr_account (fi_id, swift_bic, iban) WHERE valid_to IS NULL AND iban IS NOT NULL;
CREATE UNIQUE INDEX uq_idr_account_active ON idr_account (fi_id, account_number, routing_number)
    WHERE valid_to IS NULL;

-- ----------------------------------------------------------------
-- CUSTOMER / MEMBER
-- PII stored in plaintext (SSN, email, phone, name, DOB, address).
-- Protected by RLS + OAuth scopes, NOT tokenization.
-- ----------------------------------------------------------------

CREATE TABLE idr_customer (
    idr_customer_id         UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    fi_id                   VARCHAR(64)     NOT NULL,
    entity_type             entity_type     NOT NULL DEFAULT 'UNKNOWN',
    profile_completeness    profile_completeness NOT NULL DEFAULT 'MINIMAL_STUB',
    resolution_method       resolution_method    NOT NULL DEFAULT 'DETERMINISTIC',
    status                  entity_status   NOT NULL DEFAULT 'ACTIVE',
    confidence_score        NUMERIC(4,3)    NOT NULL DEFAULT 0.0
                                CHECK (confidence_score BETWEEN 0.0 AND 1.0),

    -- ---- IDENTITY FIELDS (plaintext, RLS-protected) ----------------
    -- BK-1: SSN / TIN (plaintext; hashed at query/comparison time for blocking)
    ssn                     VARCHAR(11)     NULL,   -- SSN: '123-45-6789' or digits
    ein                     VARCHAR(10)     NULL,   -- EIN for BUSINESS entities
    -- BK-3: Email (plaintext; normalized to lowercase for blocking)
    email                   VARCHAR(320)    NULL,
    -- BK-4: Phone (plaintext; E.164 normalized for blocking)
    phone                   VARCHAR(20)     NULL,
    -- BK-5: Core CIF key
    bk5_core_cif_key        VARCHAR(255)    NULL,   -- source_system:source_customer_id
    -- BK-6: Name + Zip (derived at resolution time from name_last + zip5)
    name_first              VARCHAR(128)    NULL,
    name_last               VARCHAR(128)    NULL,
    name_display            VARCHAR(255)    NULL,   -- full name or business name
    dob                     DATE            NULL,   -- date of birth (individuals only)
    zip5                    VARCHAR(5)      NULL,
    address_line1           VARCHAR(255)    NULL,
    address_line2           VARCHAR(255)    NULL,
    city                    VARCHAR(128)    NULL,
    state_code              CHAR(2)         NULL,
    country_code            CHAR(2)         NULL,
    -- ---------------------------------------------------------------

    entity_subtype          VARCHAR(64)     NULL,   -- e.g. 'SOLE_PROPRIETOR', 'TRUST'

    -- Global link (populated by EP-08 nightly batch)
    idr_global_person_id    UUID            NULL,   -- FK to idr_global_links

    -- Source linkage
    source_system           VARCHAR(64)     NULL,
    source_customer_id      VARCHAR(255)    NULL,

    -- Temporal columns (S-01-01)
    valid_from              TIMESTAMPTZ     NOT NULL DEFAULT now(),
    valid_to                TIMESTAMPTZ     NULL,
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT now()
);

-- RLS (S-01-02): FI tenant isolation
ALTER TABLE idr_customer ENABLE ROW LEVEL SECURITY;
CREATE POLICY idr_customer_fi_isolation ON idr_customer
    USING (fi_id = current_setting('app.fi_id', true));

-- Blocking key indexes — note: BK-1 uses SHA-256 at query time; index the plaintext column
-- for within-FI lookups (RLS ensures cross-FI isolation at DB layer)
CREATE INDEX idx_idr_customer_bk1_ssn  ON idr_customer (fi_id, ssn)   WHERE valid_to IS NULL AND ssn IS NOT NULL;
CREATE INDEX idx_idr_customer_bk1_ein  ON idr_customer (fi_id, ein)   WHERE valid_to IS NULL AND ein IS NOT NULL;
CREATE INDEX idx_idr_customer_bk3      ON idr_customer (fi_id, email) WHERE valid_to IS NULL AND email IS NOT NULL;
CREATE INDEX idx_idr_customer_bk4      ON idr_customer (fi_id, phone) WHERE valid_to IS NULL AND phone IS NOT NULL;
CREATE INDEX idx_idr_customer_bk5      ON idr_customer (fi_id, bk5_core_cif_key) WHERE valid_to IS NULL;
CREATE INDEX idx_idr_customer_bk6      ON idr_customer (fi_id, name_last, zip5)  WHERE valid_to IS NULL;
CREATE INDEX idx_idr_customer_global   ON idr_customer (idr_global_person_id) WHERE idr_global_person_id IS NOT NULL;
CREATE INDEX idx_idr_customer_fi       ON idr_customer (fi_id, status) WHERE valid_to IS NULL;

-- ----------------------------------------------------------------
-- CUSTOMER → ACCOUNT  (many-to-many for joint accounts)
-- ----------------------------------------------------------------

CREATE TABLE idr_customer_account (
    idr_customer_id     UUID        NOT NULL REFERENCES idr_customer (idr_customer_id),
    idr_account_id      UUID        NOT NULL REFERENCES idr_account  (idr_account_id),
    role                VARCHAR(32) NOT NULL DEFAULT 'PRIMARY',  -- PRIMARY, JOINT, BENEFICIARY
    linked_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    unlinked_at         TIMESTAMPTZ NULL,
    PRIMARY KEY (idr_customer_id, idr_account_id)
);

CREATE INDEX idx_cust_acct_account ON idr_customer_account (idr_account_id) WHERE unlinked_at IS NULL;

-- ----------------------------------------------------------------
-- HOUSEHOLD
-- ----------------------------------------------------------------

CREATE TYPE household_link_type AS ENUM (
    'JOINT_ACCOUNT',        -- deterministic: two owners on same account
    'SHARED_ADDRESS',       -- probabilistic address match (Phase 3 / opt-in FIs only)
    'MANUAL'                -- analyst-created link
);

CREATE TYPE household_link_confidence AS ENUM (
    'VERIFIED',     -- joint account (deterministic)
    'INFERRED'      -- address match (probabilistic)
);

CREATE TABLE idr_household (
    idr_household_id    UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    fi_id               VARCHAR(64) NOT NULL,
    status              VARCHAR(32) NOT NULL DEFAULT 'ACTIVE',
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    dissolved_at        TIMESTAMPTZ NULL
);

ALTER TABLE idr_household ENABLE ROW LEVEL SECURITY;
CREATE POLICY idr_household_fi_isolation ON idr_household
    USING (fi_id = current_setting('app.fi_id', true));

CREATE TABLE idr_household_member (
    idr_household_id    UUID        NOT NULL REFERENCES idr_household (idr_household_id),
    idr_customer_id     UUID        NOT NULL REFERENCES idr_customer  (idr_customer_id),
    fi_id               VARCHAR(64) NOT NULL,
    link_type           household_link_type        NOT NULL,
    link_confidence     household_link_confidence  NOT NULL,
    match_basis         JSONB       NULL,   -- e.g. {"type": "JOINT_ACCOUNT", "account_id": "..."}
    joined_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    left_at             TIMESTAMPTZ NULL,
    PRIMARY KEY (idr_household_id, idr_customer_id)
);

ALTER TABLE idr_household_member ENABLE ROW LEVEL SECURITY;
CREATE POLICY idr_household_member_fi_isolation ON idr_household_member
    USING (fi_id = current_setting('app.fi_id', true));

CREATE INDEX idx_hh_member_customer ON idr_household_member (idr_customer_id) WHERE left_at IS NULL;

-- ----------------------------------------------------------------
-- POINT-IN-TIME SNAPSHOT VIEW  (S-01-01 AC: temporal queries)
-- ----------------------------------------------------------------

CREATE OR REPLACE VIEW idr_customer_current AS
    SELECT * FROM idr_customer WHERE valid_to IS NULL AND status = 'ACTIVE';

CREATE OR REPLACE VIEW idr_account_current AS
    SELECT * FROM idr_account WHERE valid_to IS NULL;

-- Usage: set app.fi_id = 'fi_first_midwest'; SELECT * FROM idr_customer_current;

-- ----------------------------------------------------------------
-- FLYWAY BASELINE SENTINEL  (S-01-04)
-- ----------------------------------------------------------------
-- This migration is V1__entity_data_model.sql
-- Subsequent migrations: V2__pci_vault.sql, V3__resolution_engine.sql
