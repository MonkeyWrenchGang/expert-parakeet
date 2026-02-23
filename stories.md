# User Stories

Stories follow: **As a [actor], I want [capability], so that [outcome].**
Acceptance criteria are prefixed with `AC:`.

---

## EP-01 — Entity Data Model & Schema

### S-01-01 Entity Schema DDL
As a platform engineer, I want Account, Customer/Member, and Household tables with temporal columns (valid from, valid to), so that full entity history is preserved and any point-in-time snapshot is queryable without data loss.
- AC: Tables created with idr_customer_id (UUID PK), entity_type, profile_completeness, confidence_score, resolution_method, created_at, updated_at, valid_from, valid_to.
- AC: Household table has FK to Customer/Member; Customer/Member has FK to Account.
- AC: Temporal queries return point-in-time snapshots via SQL view.
- AC: All tables created via versioned Flyway migrations.
- AC: Schema passes validation against documented field specifications in design doc §4.

### S-01-02 PostgreSQL RLS Tenant Isolation
As a security architect, I want Row-Level Security policies on all entity tables, so that an FI can never read another FI's raw entity records regardless of query credentials.
- AC: RLS enabled on all entity tables with policy: `current_setting('app.fi_id') = fi_id`.
- AC: Session variable `app.fi_id` set at connection time by the API layer.
- AC: Integration test confirms FI-A token cannot read FI-B rows.
- AC: RLS bypass role restricted to JHBI internal service account only.

### S-01-03  Entity Change Events
As a downstream analytics consumer, I want the ablity to snag change events on every entity create, update, or merge, so that I can react to identity changes in real time without polling the database.
- AC: Topic `idr.entity.events` exists with schema-registry-registered Avro schema.
- AC: Events emitted for CREATE, UPDATE, MERGE, and STUB_CREATED operations.
- AC: Event payload includes: event_type, idr_customer_id, fi_id, entity_type, confidence_score, resolution_method, timestamp.
- AC: At-least-once delivery guaranteed; consumers are idempotent on event_id.

### S-01-04 Migration Framework & Baseline
As a DevOps engineer, I want a repeatable database migration framework, so that schema changes are versioned, applied automatically on deploy, and safe to roll back.
- AC: Flyway configured for all environments (dev, staging, prod).
- AC: Baseline migration V1 creates all Phase 1 tables and indexes.
- AC: Migration history table prevents re-running applied scripts.
- AC: Rollback scripts documented for all migrations.

---

## EP-02 — Identifier Normalization & RFM Service

### S-02-01 Email Normalization & Quality Scoring
As a data engineer, I want emails normalized to RFC 5321 canonical form with quality signals, so that fuzzy matching is eliminated and email reputation is tracked per FI.
- AC: Normalization: lowercase, strip leading/trailing whitespace, remove sub-addressing (+tag), validate format.
- AC: IDN (Internationalized Domain Names) converted to ASCII via punycode.
- AC: Quality score (0–1) computed from: domain reputation, MX validity, deliverability signals, complaint rate.
- AC: Disposable/temporary email provider detection (optional business logic per FI).
- AC: Unit test confirms " John.Doe+promo@EXAMPLE.COM " → "john.doe@example.com" with quality 0.88.

### S-02-02 Phone Normalization & Carrier Validation
As a resolution engineer, I want phone numbers normalized to ITU E.164 with carrier metadata, so that Zelle proxies and phone-based p2p transactions resolve consistently.
- AC: Normalization: extract digits, add country code if missing (requires geolocation context or explicit input), format as +CC-XXX...X (1–15 digits).
- AC: Validation: carrier file lookup (NANP for US, region-specific for intl).
- AC: Metadata: carrier_type (MOBILE, LANDLINE, VOIP), carrier_name, assigned_status.
- AC: Quality score includes: carrier validity, VoIP risk, recent number porting, TCPA DNC flag.
- AC: Unit test: "(201) 555-0123" (US context) → "+12015550123", carrier_type="MOBILE", quality=0.91.

### S-02-03 Address Normalization & CASS Certification
As a data engineer, I want addresses normalized to USPS/UPU standards with postal validation, so that wire beneficiary addresses and billing addresses are unambiguous.
- AC: USPS standardization (US): parse street/apt, validate ZIP+4, uppercase, state→abbrev, format: {Number} {Name} {Type} {Apt}, {City}, {State} {ZIP_PLUS_4}.
- AC: International address parsing per UPU standards (country-specific postal codes and conventions).
- AC: CASS-certified validation when available; quality score reflects match accuracy.
- AC: Address type categorization: RESIDENTIAL, COMMERCIAL, PO_BOX.
- AC: Move history detection (via National Change of Address file, if available).
- AC: Unit test: "123 MaIn st apt 5, sf ca 94102" → "123 MAIN ST APT 5, SAN FRANCISCO, CA 94102-1234", validation_status="CASS_CERTIFIED".

### S-02-04 RFM Event Tracking & Aggregation
As a platform engineer, I want to track Recency/Frequency/Monetary for each normalized identifier across all payment sources, so that identity enrichment and risk scoring can use temporal signals.
- AC: RFM event log: identifier_id, source_product, event_timestamp, amount (if available), event type.
- AC: Aggregation: frequency (count by 30d/90d/lifetime), last_seen (day-level precision, not minute), monetary_sum (30d/90d/lifetime).
- AC: Atomic writes: each payment event creates exactly one RFM entry per identifier (no double-counting after merges).
- AC: Retention: RFM aggregates kept for 3 years; raw event log for 1 year (compliance).
- AC: Performance: RFM lookup returns cached aggregates in < 20ms for 90% of queries.

### S-02-05 Privacy-Preserving RFM API (Bucketing & Differential Privacy)
As a JHBI compliance officer, I want RFM exposed to external systems with identifiers and exact sources hidden, so that we meet GDPR/CCPA/GLBA privacy requirements.
- AC: Internal API (JHBI only): full granular RFM + source product names (e.g., "ach_eps", "payrailz_p2p").
- AC: External API (FI-facing): aggregated RFM with frequency/recency bucketed, no exact counts or timestamps.
- AC: Thresholds: expose RFM tier only if frequency >= 3 in 90d (reduce re-identification risk).
- AC: Differential privacy option (epsilon=0.5): Laplace noise added to frequency counts; provable privacy guarantee.
- AC: Source anonymization: return "ACH", "P2P", "WIRE" product categories, not specific adapters or source systems.
- AC: Monetary value: returned as range (e.g., "$500–$1000") not exact amount.
- AC: Test: confirm same normalized email queried by FI-A and FI-B returns same RFM tier but different privacy-level aggregates based on scope.

### S-02-06 RFM Integration Tests
As a QA engineer, I want end-to-end tests of normalization, RFM tracking, and privacy API, so that regressions in identifier handling and privacy are caught before deployment.
- AC: Test corpus: 50 emails (valid, disposable, intl), 30 phone numbers (US, intl, VoIP), 20 addresses (residential, commercial, moved).
- AC: RFM accuracy: events from multiple adapters coalesced to same identifier; frequency counts correct.
- AC: Privacy tests: differential privacy noise applied; external API masks sources and exact counts.
- AC: Cross-contamination test: email/phone/address from FI-A is NOT visible to FI-B query (even normalized).
- AC: Normalization idempotence: normalize(normalize(value)) == normalize(value).
- AC: CI pipeline: all tests pass on every commit.

---

## EP-03 — Blocking Key Derivation Service

### S-03-01 BK-1: SSN/TIN Normalization & Matching
As a resolution engineer, I want BK-1 derived from SSN/TIN plaintext with normalization, so that SSN-based exact matches produce Tier-1 DEFINITIVE resolution decisions.
- AC: BK-1 key derived as normalized SSN/TIN for per-FI matching (strip non-digits).
- AC: BK-1 global variant uses same normalization for JH-global linking.
- AC: Key derivation invoked for all payment events containing SSN or EIN attributes.
- AC: Derived key written to Redis inverted index: `BK1:{normalized_value}` → `[idr_customer_id, ...]`.

### S-03-02 BK-2: Account + Routing Normalization
As a resolution engineer, I want BK-2 derived from plaintext account number and routing number, so that direct account continuity signals produce Tier-2 HIGH matches.
- AC: BK-2 = `normalize(account_number) + ':' + routing_number` (routing is not PII).
- AC: Account normalization: strip non-alphanumeric characters.
- AC: Both originator and destination account identifiers derived from each payment event.
- AC: Redis index updated atomically on event ingestion.
- AC: Stale index entries cleaned up on entity merge or deletion.

### S-03-03 BK-3: Email Normalization
As a resolution engineer, I want BK-3 derived from normalized email, so that email-based matches within an FI produce Tier-3 VERIFIED decisions.
- AC: Normalization: lowercase, strip whitespace, strip sub-addressing (+tag).
- AC: Matching is exact on normalized value.


### S-03-04 BK-4: Phone / Zelle Normalization
As a resolution engineer, I want BK-4 derived from normalized phone and Zelle proxy addresses, so that phone and Zelle proxy matches produce Tier-3 VERIFIED decisions.
- AC: Zelle proxy address treated as phone if it is a phone number; as email if it is an email address.
- AC: E.164 normalization applied to phone numbers.
- AC: Derived for both originator and destination parties.


### S-03-05 BK-6: Name + Zip5 Normalization (Secondary Only)
As a resolution engineer, I want BK-6 derived from normalized name and postal zip code but only valid as a secondary signal, so that weak name matches never trigger auto-merges.
- AC: BK-6 = `normalize(last_name) + ':' + zip5`.
- AC: Normalization: uppercase, strip punctuation, normalize unicode.
- AC: BK-6 NEVER used as sole blocking key — resolution engine enforces this rule.
- AC: BK-6 can elevate a Tier-4 match toward Tier-3 only when a primary key is also matched.
- AC: Unit test verifies BK-6-only candidate lookup returns empty result.

### S-03-06 Inverted Index & Candidate Lookup API
As a resolution engine, I want an inverted index mapping each blocking key value to a list of candidate entity IDs, so that candidate retrieval completes in O(1) time regardless of entity volume.
- AC: Redis SADD used to maintain sets: `BK_TYPE:{normalized_value}` → set of idr_customer_ids.
- AC: Candidate lookup API: given a list of blocking keys, returns union of matching entity IDs.
- AC: Lookup P99 latency < 5ms for sets up to 10k members.
- AC: Index TTL and cleanup strategy defined for merged/deleted entities.
- AC: Redis persistence (AOF) enabled to survive restarts.

---

## EP-04 — Resolution Engine Core

### S-04-01 Candidate Generation Pipeline
As a resolution engine, I want to retrieve candidate entity IDs from the blocking index for all blocking keys derived from an inbound payment event, so that I compare only plausible matches without O(N²) cost.
- AC: Pipeline accepts a normalized IdentityEvent and returns a deduplicated candidate entity ID list.
- AC: Candidates retrieved from Redis for all applicable BKs.
- AC: BK priority order respected: BK-1 → BK-2 → BK-5 → BK-3 → BK-4 → BK-6.
- AC: Candidate list capped at 200 per event; overflow logged and flagged for review.
- AC: Stateless and horizontally scalable — no shared mutable state between workers.

### S-04-02 Tier Assignment (Confidence Bucketing)
As a resolution engineer, I want each candidate match assigned to a confidence tier (1–5) based on which blocking keys matched, so that downstream actions are governed by a consistent confidence framework.
- AC: Tier 1 (DEFINITIVE, 1.0): BK-1 match within FI.
- AC: Tier 2 (HIGH, 0.90–0.99): BK-2 or BK-5 match.
- AC: Tier 3 (VERIFIED, 0.85–0.92): BK-3 or BK-4 match.
- AC: Tier 4 (INFERRED, 0.65–0.84): BK-6 secondary match or BK-7 (wires).
- AC: Tier 5 (UNRESOLVED, < 0.65): BK-8 only or no match.
- AC: Tier assignment logged with: tier, matched_bks, confidence_score, idr_customer_id, event_id.

### S-04-03 Auto-Merge (Tier 1–3)
As a resolution engineer, I want Tier 1–3 matches to auto-merge into the existing entity, so that high-confidence matches produce unified entity records without human review.
- AC: Tier 1 and Tier 2 always auto-merge (no conflict check required).
- AC: Tier 3 auto-merges if no conflicting BK-1 exists on the candidate entity; otherwise routes to review.
- AC: Merge operation updates entity profile_completeness and resolution_method.
- AC: Entity event emitted with event_type=MERGE.
- AC: Merge is idempotent: replaying the same event_id produces no duplicate merge.

### S-04-04 External Stub Creation (Tier 4–5)
As a resolution engineer, I want Tier 4 and Tier 5 events to create or update an EXTERNAL_STUB entity rather than auto-merging, so that weak matches never corrupt verified identity profiles.
- AC: Tier 4: EXTERNAL_STUB created with available signals; flagged for Phase 3 ML training.
- AC: Tier 5: MINIMAL_STUB created with only the signals available from the event.
- AC: Stubs are promotable: if a future Tier 1–3 match resolves the same party, stub is promoted to full entity.
- AC: Stub creation emits STUB_CREATED Kafka event.
- AC: Stubs counted and reported in daily resolution quality metrics.

### S-04-05 Manual Review Queue (Tier 3 Conflicts) (phase 2)
As a resolution analyst, I want conflicting Tier-3 matches routed to a review queue, so that ambiguous identity cases are resolved by a human rather than an automated merge that could corrupt entity data.
- AC: Review queue implemented as a table with status (PENDING, RESOLVED, REJECTED).
- AC: Events routed to queue include: event_id, candidate_entity_ids, matched_bks, conflict_reason.
- AC: API endpoint to list pending reviews, accept merge, or reject with reason.
- AC: Accepted merges proceed as per S-03-03; rejected cases create new stub.
- AC: Queue age alert fires if items remain PENDING > 5 business days.


### S-04-06 Resolution Pipeline Integration Tests
As a QA engineer, I want an end-to-end integration test suite for the resolution pipeline, so that regressions in blocking, tier assignment, and merge logic are caught before deployment.
- AC: Test suite covers: Tier 1 SSN merge, Tier 2 account merge, Tier 3 email auto-merge, Tier 3 conflict → review, Tier 4 stub, Tier 5 minimal stub.
- AC: Test fixtures include synthetic IdentityEvent payloads for all 9 in-scope products.
- AC: Tests run against an in-memory Redis and a test PostgreSQL schema.
- AC: All tests pass in CI/CD pipeline on every PR.
- AC: Test coverage > 80% for resolution engine core classes.

---

## EP-05 — ACH (EPS / Profitstars) Adapter

### S-05-01 ACH Event Consumer & Normalization
As an integration engineer, I want a consumer for EPS/Profitstars ACH events that normalizes each transaction into two IdentityEvents (originator and destination), so that both payment parties enter the resolution pipeline.
- AC: Consumer handles Standard Entry Class codes: PPD, WEB, TEL, CCD, CTX, ARC, POP, BOC.
- AC: Both originator (ODFI side) and destination (RDFI side) IdentityEvents produced.
- AC: Account + routing normalized as BK-2; name extracted where present.
- AC: Event deduplication by ACH trace number prevents duplicate resolution for the same transaction.
- AC: Batch ACH files processed in order; individual-entry failures do not abort the batch.

### S-05-02 SEC Code → entity_type Inference
As a resolution engineer, I want the ACH SEC code automatically mapped to entity_type, so that INDIVIDUAL vs. BUSINESS classification is derived without manual intervention.
- AC: PPD, WEB, TEL → entity_type=INDIVIDUAL.
- AC: CCD, CTX → entity_type=BUSINESS.
- AC: ARC, POP, BOC → entity_type=INDIVIDUAL (check conversion).
- AC: Unknown SEC codes → entity_type=UNKNOWN with alert.
- AC: Mapping tested with representative ACH test files for each SEC code.

### S-05-03 Originator & Destination Party Extraction
As a resolution engineer, I want each ACH event to yield explicit originator and destination party records, so that both ends of every transaction are identity-resolved.
- AC: Originator party: ODFI account (normalized), routing, name (if in addenda), entity_type.
- AC: Destination party: RDFI account (normalized), routing, receiver name field, entity_type.
- AC: External parties (non-JH RDFI) create EXTERNAL_STUB (Tier 4/5).
- AC: Party role (ORIGINATOR/DESTINATION) set on IdentityEvent.
- AC: All 8 blocking keys derived where attributes are present.

### S-05-04 ACH Integration Tests
As a QA engineer, I want integration tests with sample ACH files from EPS/Profitstars, so that the adapter handles all SEC codes and edge cases correctly.
- AC: Test corpus includes one file per major SEC code (PPD, WEB, CCD, etc.).
- AC: Multi-batch file processing tested.
- AC: Reversal entries handled gracefully (no entity deletion).
- AC: Rejected ACH entries (Return codes R01–R23) do not corrupt entity state.
- AC: CI pipeline runs tests on every PR.

---

## EP-06 — FI-Scoped Query API

### S-06-01 REST Entity Query Endpoints
As an FI developer, I want REST endpoints to look up entities by ID and by payment identifiers, so that I can retrieve a resolved customer profile from my payment processing workflow.
- AC: GET /v1/entities/{idr_customer_id} returns full entity profile (FI-scoped).
- AC: GET /v1/entities?account_token={token}&routing={r} returns matching entities.
- AC: GET /v1/entities/{id}/accounts returns linked accounts.
- AC: GET /v1/entities/{id}/household returns household members.
- AC: 401 returned if token is missing or expired; 403 if fi_id mismatch.
- AC: All responses include resolution_method and confidence_score.


### S-06-03 OpenAPI Spec & Developer Portal
As an FI developer, I want an OpenAPI 3.0 spec and Swagger UI, so that I can understand the API contract and test endpoints without writing code.
- AC: OpenAPI spec generated from code annotations (no manual spec drift).
- AC: All endpoints, request schemas, response schemas, and error codes documented.
- AC: Swagger UI hosted at /v1/docs in non-production environments.
- AC: API changelog maintained per semver; breaking changes require major version bump.

### S-06-04 API Rate Limiting & Auth Enforcement (phase 2 / 3)
As a platform operator, I want rate limiting and OAuth enforcement on the API, so that no FI can overwhelm the system and cross-tenant access is impossible.
- AC: OAuth 2.0 client credentials flow; fi_id extracted from JWT sub claim.
- AC: Rate limit: 1,000 requests/minute per fi_id (configurable).
- AC: Rate limit exceeded returns HTTP 429 with Retry-After header.
- AC: All requests logged with: fi_id, endpoint, latency, status code.
- AC: API latency SLO: P99 < 200ms for entity-by-ID lookups.

### S-06-05 API Integration & Contract Tests
As a QA engineer, I want a contract test suite for the Query API, so that API consumers have confidence that the schema does not change unexpectedly.
- AC: Pact consumer-driven contract tests defined for common FI use cases.
- AC: Contract tests run in CI on every PR and on every API change.
- AC: Happy path, 404, 403, and rate-limit scenarios covered.
- AC: Tests run against a test entity store with seeded fixture data.

---

## EP-07 — JH-Global Link Table

### S-07-01 idr_global_person_id Link Table Schema
As a JHBI engineer, I want a link table that maps a global UUID to (fi_id, idr_customer_id) pairs, so that the same individual appearing at multiple FIs can be counted and tracked without merging their FI-scoped entities.
- AC: Table: idr_global_links (idr_global_person_id UUID, fi_id, idr_customer_id, qualifying_bk, linked_at).
- AC: No PII stored — only tokens and opaque IDs.
- AC: Table accessible only to JHBI internal service account (not via FI-facing API).
- AC: idr_global_person_id populated back to the entity record for each linked FI entity.
- AC: Audit log records every global link creation or dissolution.

---

## EP-08 — Observability, Audit Logging & Infrastructure

### S-08-01 Structured Logging & Distributed Tracing
As a reliability engineer, I want structured JSON logs and OpenTelemetry trace context on every resolution event, so that I can trace a payment event from ingestion to entity write in a single query.
- AC: All services emit structured JSON logs with: trace_id, span_id, fi_id, event_id, service_name, level, message.
- AC: OpenTelemetry SDK integrated; traces exported to OTLP endpoint.
- AC: Resolution pipeline spans: Ingest → Tokenize → DeriveKeys → CandidateGen → TierAssign → EntityWrite.
- AC: Log and trace correlated by trace_id.
- AC: No PII in logs (event_id used as opaque reference).

### S-08-02 Resolution Pipeline Metrics Dashboard (phase 2)
As a platform engineer, I want a metrics dashboard showing resolution throughput, tier distribution, and pipeline latency, so that I can confirm the system meets its SLOs and detect anomalies.
- AC: Metrics: events_per_second, resolution_tier_distribution (T1–T5 %), pipeline_latency_p50/p95/p99, redis_lookup_latency, entity_write_latency.
- AC: Dashboard published in Grafana with 1-minute refresh.
- AC: Alert: p99 pipeline latency > 500ms for > 5 minutes.
- AC: Alert: Tier-5 (UNRESOLVED) rate > 30% over a 1-hour window.
- AC: Kafka consumer lag monitored per topic partition.

### S-08-03 Immutable Entity Audit Log
As a compliance officer, I want an immutable audit trail of every entity state change, so that we can reconstruct the full identity history of any entity for regulatory or legal purposes.
- AC: Audit log table: entity_id, event_type, old_values (JSON), new_values (JSON), actor, timestamp, correlation_id.
- AC: Append-only: no UPDATE or DELETE permitted on audit_log table.
- AC: Retention: 7 years minimum, enforced by table partition policy.
- AC: Queryable by entity_id and date range.
- AC: Audit log export API for compliance team (JHBI internal only).


### S-08-05 Load Test: 10k Events/Minute Throughput
As a platform engineer, I want a load test harness that simulates 10,000 resolution events per minute, so that we can validate throughput and latency targets before production go-live.
- AC: Load generator produces realistic IdentityEvent payloads at 10k/min for 30 minutes.
- AC: Pipeline sustains throughput with p99 latency < 500ms.
- AC: No entity data corruption observed under load (post-run validation).
- AC: Redis and PostgreSQL metrics recorded during load test.
- AC: Load test results documented; bottlenecks identified and addressed or tracked as risks.

---

## EP-09 — PayCenter Adapter (RTP, FedNow, Zelle)

### S-09-01 RTP & FedNow Consumer & Normalization
As an integration engineer, I want RTP and FedNow events from PayCenter normalized to IdentityEvent format, so that real-time payment parties are resolved with account-level signals.
- AC: Consumer handles PayCenter RTP and FedNow event schema.
- AC: Originator and destination IdentityEvents produced per transaction.
- AC: Account + routing normalized as BK-2; fi_id set correctly for JH-side participants.
- AC: External FI participants receive EXTERNAL_STUB via BK-2 or account identifier only.
- AC: Integration test validates normalization against 100 sample PayCenter events.

### S-09-02 Zelle Proxy Address Extraction (BK-3 / BK-4)
As a resolution engineer, I want Zelle proxy addresses extracted and routed to BK-3 (email) or BK-4 (phone) derivation, so that Zelle participants are matched against email- and phone-linked entities.
- AC: Proxy address type detected: phone (E.164) → BK-4; email → BK-3.
- AC: Both originator and destination proxy addresses processed where present.
- AC: Per-FI HMAC applied before any index lookup.
- AC: Test covers phone proxy, email proxy, and account-number-only Zelle transactions.

### S-09-03 PayCenter Integration Tests
As a QA engineer, I want integration tests for the PayCenter adapter covering all three rails, so that regression is caught before production deployment.
- AC: Tests cover: RTP credit, FedNow debit, Zelle phone proxy, Zelle email proxy, Zelle unknown proxy.
- AC: End-to-end: event consumed → correct IdentityEvent produced → correct BKs derived.
- AC: DLQ behavior validated for malformed PayCenter events.
- AC: CI integration: tests run on every adapter code change.

---

## EP-10 — Payrailz Adapter (P2P, A2A, Bill Pay)

### S-10-01 Payrailz Event Consumer & Normalization
As an integration engineer, I want Payrailz P2P, A2A, and bill pay events normalized to IdentityEvent format, so that all three payment types feed the resolution engine.
- AC: Consumer subscribes to Payrailz CDC/event topic.
- AC: IdentityEvent produced for originator and destination of each transaction.
- AC: Payment type (P2P/A2A/BILL_PAY) preserved in source_product field.
- AC: Normalization handles both scheduled and instant Payrailz transactions.
- AC: 100 sample Payrailz events processed without schema errors in integration test.

### S-10-02 P2P Proxy (Phone/Email) Signal Handling
As a resolution engineer, I want P2P transactions to extract email and phone proxy identifiers as BK-3/BK-4, so that open-loop P2P recipients are identity-resolved via their contact information.
- AC: Phone proxies detected and normalized as BK-4.
- AC: Email proxies detected and normalized as BK-3.
- AC: Recipients with no core account link receive Tier-3 VERIFIED match if proxy token matches.
- AC: P2P recipient without any matching profile receives Tier-5 MINIMAL_STUB.

### S-10-03 A2A Account Link Signal Handling
As a resolution engineer, I want A2A transfers to produce BK-2 signals for both originator and destination accounts, so that linked external accounts strengthen the entity profile.
- AC: Both originator and destination account identifiers derived for A2A.
- AC: External linked accounts (non-JH) produce EXTERNAL_STUB enriched with BK-2 signal.
- AC: Successful A2A match to existing entity updates profile_completeness if new signals added.
- AC: Test confirms A2A signals upgrade existing stubs to Tier-2 HIGH when BK-2 matches.

### S-10-04 Payrailz Integration Tests
As a QA engineer, I want Payrailz integration tests covering all three payment types, so that adapter correctness is validated in CI.
- AC: Tests cover: P2P email proxy, P2P phone proxy, A2A same-FI, A2A external, bill pay biller resolution.
- AC: End-to-end validation in CI environment.
- AC: DLQ scenario tested for malformed Payrailz events.

---

## EP-11 — Jack Henry Wires Adapter (FedWire, Corpay/SWIFT)

### S-11-01 FedWire Consumer & Normalization
As an integration engineer, I want FedWire events normalized to IdentityEvent format with account + routing (BK-2) and name (BK-6 secondary), so that domestic wire counterparties are resolved.
- AC: Consumer handles FedWire message format from JH Wires system.
- AC: Originator and beneficiary IdentityEvents produced per wire.
- AC: Account + routing normalized as BK-2 for both parties.
- AC: Beneficiary name and city extracted for BK-6 secondary signal.
- AC: Domestic external beneficiaries receive EXTERNAL_STUB at Tier 2–4 depending on available signals.

### S-11-02 BK-7: SWIFT BIC + IBAN Token (International Wires)
As a resolution engineer, I want international wire beneficiary data to produce BK-7 blocking keys (SWIFT BIC + FPE-normalized IBAN), so that recurring international wire beneficiaries are linked across transactions.
- AC: BK-7 = `swift_bic + ':' + fpe(iban_or_account_number)`.
- AC: SWIFT BIC validated against known BIC registry (reject unknown BICs).
- AC: IBAN tokenized via FPE; non-IBAN foreign accounts tokenized identically.
- AC: BK-7 entities typically resolve to Tier 4 (INFERRED) due to limited identity data.
- AC: Corpay/SWIFT data gaps (missing IBAN) handled gracefully — fall back to BK-6 secondary.

### S-11-03 International Wire Beneficiary External Stubs
As a resolution engineer, I want international wire beneficiaries to receive well-structured EXTERNAL_STUB profiles, so that recurring international payment counterparties are trackable over time.
- AC: EXTERNAL_STUB created with: entity_type inferred from SWIFT BIC, bk7_token, beneficiary_name (BK-6), country_code.
- AC: profile_completeness=EXTERNAL set on all international wire stubs.
- AC: Stub updatable when subsequent wires provide additional attributes.
- AC: Stub linkable to full entity if beneficiary later opens a JH account.

### S-11-04 Wires Integration Tests
As a QA engineer, I want wires integration tests covering domestic FedWire and international Corpay/SWIFT events, so that BK-2 and BK-7 derivation is validated.
- AC: Tests: domestic wire (BK-2 match), domestic wire (BK-6 secondary, Tier 4), international IBAN (BK-7 Tier 4), international no-IBAN (BK-6 only, Tier 4).
- AC: CI pipeline executes on every wires adapter change.

---

## EP-12 — iPay Solutions Adapter

### S-12-01 iPay Event Consumer & Normalization
As an integration engineer, I want iPay events normalized to IdentityEvent format with payment type distinguished, so that the resolution engine applies the correct blocking key strategy per product.
- AC: Consumer handles iPay bill pay, CardPay, and P2P event schemas.
- AC: source_product field set to IPAY_BILL_PAY, IPAY_CARDPAY, or IPAY_P2P.
- AC: Originator and destination IdentityEvents produced for each transaction.
- AC: Schema version compatibility handled for iPay API v1 and v2.
- AC: Integration test validates normalization for 100 sample iPay events.

### S-12-02 Bill Pay Biller Resolution (BUSINESS entity_type)
As a resolution engineer, I want bill pay biller records resolved as entity_type=BUSINESS, so that utility companies, telecoms, and other billers are catalogued as business entities rather than individuals.
- AC: Biller name + biller ID mapped to entity_type=BUSINESS.
- AC: BK-5-style biller ID used as primary blocking key (biller_registry_id where available).
- AC: Recurring biller detected by biller_name + biller_id stability; entity updated not duplicated.
- AC: BILLER profile_completeness set on all bill pay biller entities.

### S-12-03 CardPay & P2P Participant Extraction
As a resolution engineer, I want CardPay and P2P participants extracted with their available proxy identifiers, so that card-to-card and open-loop P2P transfers produce correctly tiered resolution outcomes.
- AC: CardPay: account identifier (BK-2) extracted where available; otherwise Tier-5 stub.
- AC: P2P: phone/email proxy → BK-3/BK-4 (same logic as Payrailz P2P).
- AC: CardPay external recipient with no account signal receives Tier-5 MINIMAL_STUB.
- AC: Test covers: CardPay with account, CardPay without account, P2P email, P2P phone.

### S-12-04 iPay Integration Tests
As a QA engineer, I want iPay integration tests covering all three payment types in CI, so that adapter regressions are caught immediately.
- AC: Tests: bill pay (biller resolution), CardPay (with/without account), P2P (email/phone proxy).
- AC: End-to-end test: event → correct entity created/updated.
- AC: CI execution on every iPay adapter code change.

---

## EP-13 — Banno Digital Platform Adapter

### S-13-01 Banno Event Consumer & Normalization
As an integration engineer, I want Banno transfer, Zelle, and bill pay events normalized to IdentityEvent format, so that Banno payment parties enter the resolution pipeline.
- AC: Consumer handles Banno API event webhook or CDC schema.
- AC: source_product=BANNO set on all events.
- AC: Originator and destination IdentityEvents produced.
- AC: Banno-specific transfer types (internal, external, Zelle, bill pay) handled in normalization.
- AC: Integration test validates 100 sample Banno events.

### S-13-02 Banno Zelle Proxy Extraction & BK-3/BK-4 Alignment
As a resolution engineer, I want Banno Zelle proxy addresses extracted and tokenized consistently with PayCenter Zelle proxy handling, so that the same proxy address resolves to the same entity regardless of which product carried the transaction.
- AC: Phone proxy → BK-4 
- AC: Email proxy → BK-3 (
- AC: Test confirms cross-product proxy consistency within FI.

### S-13-03 Banno Integration Tests
As a QA engineer, I want Banno integration tests covering transfers, Zelle (phone + email), and bill pay in CI.
- AC: Tests: internal transfer (BK-2 both sides JH), external transfer (BK-2 stub), Zelle email, Zelle phone, bill pay biller.
- AC: End-to-end event → entity resolution validated.
- AC: CI execution on every Banno adapter code change.

---

## EP-14 — Business Payment Solutions Adapter

### S-14-01 B2V ACH & Payroll Consumer
As an integration engineer, I want B2V ACH and payroll events from Business Payment Solutions normalized to IdentityEvent format, so that business payment parties enter the resolution pipeline.
- AC: Consumer handles Business Payment Solutions event schema (CCD, CTX ACH entries).
- AC: Business originator: entity_type=BUSINESS, EIN → BK-1 TIN hash.
- AC: Payroll batch: each employee entry produces individual IdentityEvent (PPD → entity_type=INDIVIDUAL).
- AC: Batch processing: per-entry failure does not abort batch.
- AC: Integration test validates 50 sample payroll batch events.

### S-14-02 Business Entity Resolution via EIN (BK-1 TIN)
As a resolution engineer, I want business entities to resolve via their EIN/TIN (BK-1 with entity_type=BUSINESS), so that a business appearing as originator across multiple products is consistently identified.
- AC: entity_type=BUSINESS set; profile_completeness=FULL for JH business customers.
- AC: Business entity resolution yields Tier-1 DEFINITIVE when EIN hash matches existing entity.
- AC: Cross-FI business linking uses platform-salt EIN hash, same as individual SSN linking.

### S-14-03 Remittance Data & External Counterparty Stubs
As a resolution engineer, I want remittance data from business payments to enrich external counterparty stubs, so that payees with remittance info are more identifiable over time.
- AC: Remittance addenda (CTX) parsed for payee name, address, invoice reference.
- AC: Payee stub enriched with remittance attributes if not already present.
- AC: Remittance-only payees (no account identifier available) receive Tier-4 INFERRED stubs.
- AC: Payee stubs linkable across multiple remittance payments from the same originator.

### S-14-04 Business Payment Solutions Integration Tests
As a QA engineer, I want integration tests for Business Payment Solutions covering B2V ACH, payroll, and remittance scenarios.
- AC: Tests: B2V ACH (EIN resolution), payroll batch (individual employee stubs), remittance (CTX enrichment).
- AC: End-to-end CI test execution on every adapter change.

---

## EP-15 — EPS Check / RDC Adapter & Tap2Local Stubs

### S-15-01 Check 21 / RDC Event Consumer & Normalization
As an integration engineer, I want Check 21 and RDC events normalized to IdentityEvent format, so that check payor and payee identity signals enter the resolution pipeline.
- AC: Consumer handles EPS Check/RDC event schema.
- AC: Payor: account + routing normalized as BK-2 (SEC code ARC/POP/BOC → entity_type=INDIVIDUAL).
- AC: Payee name extracted as BK-6 secondary signal.
- AC: Check amount, date, and check number preserved in event metadata (not identity signals).
- AC: Integration test validates 50 sample Check 21 events.

### S-15-02 Check-to-ACH Conversion Signal Preservation
As a resolution engineer, I want check conversion events to preserve the original check payor's account signal, so that accounts identified via check also appear in the ACH blocking index.
- AC: Converted check payor's BK-2 token indexed identically to ACH originator BK-2.
- AC: If same account appears in both ACH feed and check feed, entity merges on BK-2 match.
- AC: Conversion metadata (original check number) stored in event but not used as a blocking key.
- AC: Test confirms BK-2 consistency between ACH and check conversion for the same account.

### S-15-03 BK-8: Tokenized PAN Deriver (Tap2Local / EPS Gateway)
As a resolution engineer, I want card-present transaction PANs normalized as BK-8, so that recurring card-present customers receive a trackable EXTERNAL_STUB even without card-issuer identity data.
- AC: BK-8 = card_network_token (Moov/gateway token) or FPE(PAN) where raw PAN is available.
- AC: BK-8 always resolves to Tier 5 (UNRESOLVED) only — never used for auto-merge.
- AC: Tap2Local card token indexed in Redis BK8 namespace separately from BK1–7.
- AC: BK-8 stub promotable if cardholder later identified via another signal (BK-1/BK-2).
- AC: Test confirms BK-8-only match creates Tier-5 MINIMAL_STUB, not FULL entity.

### S-15-04 Card-Present External Stub Creation
As a resolution engineer, I want card-present Tap2Local transactions to create EXTERNAL_STUB profiles linked by BK-8, so that merchant-level analytics can track repeat card-present customers without PII.
- AC: EXTERNAL_STUB created with: bk8_token, merchant_id, transaction_count, first/last_seen timestamps.
- AC: Stub aggregates transaction count across visits (not individual transaction records).
- AC: No PAN or cardholder name stored in stub — only network token.
- AC: Stub promotable to full entity if cardholder identified via other payment rails.

### S-15-05 Check / RDC / Tap2Local Integration Tests
As a QA engineer, I want integration tests for Check 21, RDC, and Tap2Local scenarios in CI.
- AC: Tests: Check 21 payor (BK-2 match Tier 2), RDC payee (BK-6 Tier 4), Tap2Local (BK-8 Tier 5 stub).
- AC: Check-to-ACH signal consistency test.
- AC: CI execution on every adapter code change.

