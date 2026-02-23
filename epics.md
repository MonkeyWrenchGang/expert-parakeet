# Epics

> **Note:** Original scope reduced: EP-05 (SilverLake/Symitar) and EP-17–20 (probabilistic/graph features) removed. NEW EP-02: Identifier Normalization & RFM Service replaces deferred EP-02 (tokenization vault). Architecture uses plaintext PII with RLS protection instead of encryption.


| ID | Epic | Design Coverage | Priority |
| --- | --- | --- | --- |
| EP-01 | Entity Data Model & Schema | §4 Entity Model, §6 API Design | P0 |
| EP-02 | Identifier Normalization & RFM Service | §4 Entity Model, Email/Phone/Address Standards | P0 |
| EP-03 | Blocking Key Derivation Service | §5 Blocking & Bucketing, BK-1–BK-8, Normalization | P0 |
| EP-04 | Resolution Engine Core | §5 Blocking & Bucketing, §3 Silver Layer | P0 |
| EP-05 | ACH (EPS / Profitstars) Adapter | §2 Scope, §3 Silver Layer, SEC Code Inference | P0 |
| EP-06 | FI-Scoped Query API | §6 API Design | P0 |
| EP-07 | JH-Global Link Table | §4.4 Two-Tier Architecture, §7 Privacy & Compliance | P0 |
| EP-08 | Observability, Audit Logging & Infrastructure | §8 Implementation Phasing, NFR | P0 |
| EP-09 | PayCenter Adapter (RTP, FedNow, Zelle) | §2 Scope, BK-3, BK-4 | P1 |
| EP-10 | Payrailz Adapter (P2P, A2A, Bill Pay) | §2 Scope, BK-2, BK-3, BK-4 | P1 |
| EP-11 | Jack Henry Wires Adapter (FedWire, Corpay/SWIFT) | §2 Scope, BK-7 | P1 |
| EP-12 | iPay Solutions Adapter | §2 Scope, BK-2, BK-3, BK-4 | P1 |
| EP-13 | Banno Digital Platform Adapter | §2 Scope, BK-3, BK-4 | P1 |
| EP-14 | Business Payment Solutions Adapter | §2 Scope, BK-1 (EIN/TIN) | P1 |
| EP-15 | EPS Check / RDC Adapter & Tap2Local Stubs | §2 Scope, BK-2, BK-8 | P1 |

## Epic Descriptions

**EP-01 Entity Data Model & Schema**
Build the core PostgreSQL schema for Account, Customer/Member, and Household entities with temporal tables (valid_from / valid_to) for full history retention, Row-Level Security (RLS) policies enforcing FI tenant isolation, and a Kafka change-event topic (idr.entity.events) that downstream consumers subscribe to.

**EP-02 Identifier Normalization & RFM Service**
Implement services for normalizing email (RFC 5321), phone (ITU E.164), and address (USPS/UPU standards) to canonical forms, extracting quality signals (deliverability, carrier validation, CASS certification), and tracking Recency/Frequency/Monetary (RFM) attributes across all payment sources. Expose RFM through a privacy-preserving API using bucketed aggregation and differential privacy, hiding test raw identifiers and source genealogy from external consumers. Supports internal RFM linkage to blocking keys.

**EP-03 Blocking Key Derivation Service**
Implement the service that derives all 8 Blocking Keys (BK-1 through BK-8) from normalized payment event attributes (SSN, account+routing, email, phone, name+zip, etc.) and maintains the Redis inverted index mapping each key value to candidate entity IDs. Enables O(1) candidate retrieval rather than O(N²) full-table scans. Uses plaintext normalized values for matching; no encryption or tokenization.

**EP-04 Resolution Engine Core**
Implement the stateless pipeline that orchestrates candidate generation from the Redis blocking index, bucket/tier assignment (Tier 1–5) based on which blocking keys matched, automated decisions (auto-merge, auto-stub, or manual review routing), and audit logging to the match_decision_log.

**EP-05 ACH (EPS / Profitstars) Adapter**
Consume ACH credit, debit, and Same-Day ACH events from EPS / Profitstars. Extract originator and destination parties, infer entity_type from SEC codes (PPD/WEB/TEL → INDIVIDUAL; CCD/CTX → BUSINESS; ARC/POP/BOC → INDIVIDUAL), and feed the resolution engine.

**EP-06 FI-Scoped Query API**
Build the external-facing REST and GraphQL API for FI developers to query resolved entity data. Strictly scoped to a single FI per OAuth token. Exposes entity profiles, linked accounts, household groupings, and resolution metadata with SLO of P99 < 200ms.

**EP-06 JH-Global Link Table**
Build the JHBI-internal cross-FI identity link table mapping idr_global_person_id to (fi_id, idr_customer_id) pairs. Uses only BK-1 (SSN) and BK-2 (account+routing) as qualifying signals. Email and phone are intentionally excluded by design. No FI-scoped API exposes this table.

**EP-07 Observability, Audit Logging & Infrastructure**
Production-grade observability: structured OpenTelemetry logging, distributed tracing across the full resolution pipeline, resolution metrics dashboard, immutable entity audit log, Kubernetes Helm chart, and a 10k events/minute load test harness.

**EP-08 PayCenter Adapter (RTP, FedNow, Zelle)**
Consume RTP, FedNow, and Zelle events from JHA PayCenter. Extract Zelle proxy addresses (phone → BK-4, email → BK-3) with normalization consistent with other Zelle-carrying products within the same FI.

**EP-09 Payrailz Adapter (P2P, A2A, Bill Pay)**
Consume Payrailz P2P, account-to-account, and bill pay events. P2P uses email/phone proxies (BK-3/BK-4); A2A uses account+routing (BK-2); bill pay resolves billers as entity_type=BUSINESS.

**EP-10 Jack Henry Wires Adapter (FedWire, Corpay/SWIFT)**
Consume domestic FedWire and international Corpay/SWIFT wire events. Implement BK-7 (SWIFT BIC + normalized IBAN) for international wire beneficiary resolution at Tier 4 (INFERRED).

**EP-11 iPay Solutions Adapter**
Consume iPay bill pay, CardPay, and P2P events. Resolve billers as entity_type=BUSINESS; extract CardPay account+routing (BK-2) and P2P phone/email proxies (BK-3/BK-4).

**EP-12 Banno Digital Platform Adapter**
Consume Banno transfer, Zelle, and bill pay events. Apply normalized Zelle proxy extraction consistent with PayCenter to ensure cross-product proxy consistency within a single FI.

**EP-13 Business Payment Solutions Adapter**
Consume B2V ACH, payroll batches, and remittance events. Resolve business originators via EIN/TIN (BK-1 with entity_type=BUSINESS). Payroll batches produce individual EXTERNAL_STUB recipients per employee entry.

**EP-14 EPS Check / RDC Adapter & Tap2Local Stubs**
Consume Check 21 and RDC events (payor account+routing → BK-2, payee name → BK-6 secondary). Derive BK-8 (normalized PAN) for card-present Tap2Local / EPS gateway transactions, producing Tier-5 EXTERNAL_STUBs only — BK-8 never used for auto-merge.
