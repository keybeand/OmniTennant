# INVEST Requirements — OmniTenant V1

> Design status: TARGET V1

Each requirement is structured to be small enough to implement, review, and test independently. Cross-cutting requirements such as tenant isolation, distributed concurrency locks, idempotency key enforcement, HMAC webhook verification, and structured audit logging are codified as formal acceptance constraints.

---

## INVEST checklist

| Principle | Application in this backlog |
|---|---|
| **Independent** | Feature stories (e.g. Catalog Browsing, Channel Stock Allocation, and Checkout) are decoupled through explicit domain events and boundary contexts. |
| **Negotiable** | Underlying storage engines (e.g. PostgreSQL row-level locks vs. Redis Redlock distributed locks) can be refined as long as consistency and zero-oversell SLAs remain intact. |
| **Valuable** | Every story delivers quantifiable business value: tenant data isolation, stock accuracy, B2B wholesale throughput, or fast checkout under concurrency. |
| **Estimable** | Data boundaries, API endpoints, idempotency headers, tenant resolution mechanisms, and failure rollback semantics are rigorously documented. |
| **Small** | Complex workflows (such as two-phase inventory reservation and bulk CSV order upload) are decomposed into isolated API, persistence, locking, and event dispatch tasks. |
| **Testable** | Every story maps directly to verifiable acceptance criteria covering race-condition behavior, RBAC constraints, and tenant boundary enforcement. |

---

## Product backlog

| ID | User story | Value | Dependencies | Acceptance criteria |
|---|---|---|---|---|
| **US01** | As a Platform SuperAdmin, I want to authenticate via MFA-protected login so that global administrative actions remain secure. | Platform security & governance | Seeded root credentials | AC-UC01 |
| **US02** | As an organization user, I want to authenticate within my tenant scope so that my permissions and session are strictly bound to my organization. | Tenant boundary security | US01, tenant provision | AC-UC05 |
| **US03** | As a Platform SuperAdmin, I want to provision new tenant organizations and isolated database scopes so that new brands can onboard automatically. | Automated SaaS scalability | US01 | AC-UC02 |
| **US04** | As a Tenant Owner or Warehouse Operator, I want to manage product masters and multi-dimensional variants so that my catalog reflects accurate product offerings. | Catalog organization | US02 | AC-UC10 |
| **US05** | As any user, I want multi-attribute faceted search and category navigation so that products are discoverable with low latency. | Catalog discoverability | US04 | AC-UC10, AC-UC15 |
| **US06** | As a Warehouse Operator, I want to track SKUs by unique barcodes and metadata so that warehouse physical items map directly to system records. | Fulfillment accuracy | US04 | AC-UC10 |
| **US07** | As a Tenant Owner or Warehouse Operator, I want to allocate available warehouse inventory across digital sales channels so that channels operate without stock conflict. | Omnichannel allocation | US06 | AC-UC12 |
| **US08** | As a customer checking out, I want temporary distributed stock reservations with a TTL so that overselling is prevented while I finalize payment. | Zero overselling | US07, Redis lock | AC-UC16 |
| **US09** | As a Warehouse Operator, I want to define safety stock threshold buffers per SKU so that unexpected demand spikes do not deplete physical inventory. | Stockout protection | US07 | AC-UC11 |
| **US10** | As a Tenant Owner, I want to onboard B2B wholesale buyers and configure corporate credit limits so that high-value wholesale accounts can order on terms. | B2B commercial enablement | US02 | AC-UC06, AC-UC09 |
| **US11** | As a Tenant Owner, I want to configure tiered volume pricing rules so that bulk wholesale buyers receive automatic price discounts based on order quantity. | Automated wholesale pricing | US04, US10 | AC-UC09, AC-UC15 |
| **US12** | As a B2B Buyer, I want to upload bulk purchase orders via CSV/Excel with real-time validation so that hundreds of line items can be ordered instantly. | High-speed B2B ordering | US08, US11 | AC-UC18 |
| **US13** | As a B2C Shopper, I want a high-performance shopping cart with real-time stock availability indicators so that I can shop smoothly during high-traffic events. | Frictionless retail experience | US05, US07 | AC-UC15, AC-UC16 |
| **US14** | As a B2C or B2B customer, I want idempotent checkout and automated invoice generation so that duplicate charges and missing orders are eliminated. | Transaction integrity | US08, US13 | AC-UC16, AC-UC17 |
| **US15** | As an external WMS/ERP system, I want to push real-time inventory deltas via HMAC-secured webhooks so that physical stock movements update OmniTenant automatically. | Real-time warehouse sync | US07, API keys | AC-UC13, AC-UC14 |
| **US16** | As a Tenant Owner or SuperAdmin, I want immutable, structured audit logging with correlation IDs so that all mutations and security actions are traceable. | Compliance & observability | US01, US02 | AC-UC04 |
| **US17** | As a Tenant Owner, I want to invite staff members and configure role-based permissions (RBAC) so that administrative tasks are delegated safely. | Principle of least privilege | US02 | AC-UC06 |
| **US18** | As a Tenant Owner, I want to customize storefront branding and register outbound webhook endpoints so that external applications receive order lifecycle events. | Extensibility & branding | US02 | AC-UC07 |
| **US19** | As a B2B Buyer or Sales Rep, I want an AI-powered purchase order parser so that I can upload handwritten notes, PO PDFs, or raw message text and automatically generate a validated draft order with matched SKUs and volume pricing in seconds. | B2B ordering automation & zero-friction intake | US02, US04, US11 | AC-UC19 |
| **US20** | As a Warehouse Operator or Tenant Owner, I want an autonomous AI inventory copilot so that stockout runways are forecasted continuously and restock PO recommendations are generated automatically before critical stock depletion occurs. | Autonomous supply chain & stockout prevention | US07, US09 | AC-UC20 |
| **US21** | As a Tenant Owner or Merchandising Director, I want an autonomous Revenue & Markdown AI agent so that slow-moving dead stock is detected proactively and optimal markdown / flash sale pricing strategies are proposed automatically to unlock working capital. | Dead-stock liquidation & capital velocity optimization | US04, US07, US11 | AC-UC21 |

---

## Per-story INVEST review

`PASS` indicates the architectural design, boundary conditions, edge cases, and acceptance constraints provide sufficient specificity for immediate engineering and automated testing.

| Story | I | N | V | E | S | T | Architectural Notes & Boundary Conditions |
|---|---|---|---|---|---|---|---|
| **US01** | PASS | PASS | PASS | PASS | PASS | PASS | Authentication via bcrypt/Argon2 password hash + TOTP MFA. Returns Platform JWT with 15-minute expiration. |
| **US02** | PASS | PASS | PASS | PASS | PASS | PASS | Tenant context resolved via subdomain/custom domain header. Validates active tenant status before issuing tenant-scoped JWT. |
| **US03** | PASS | PASS | PASS | PASS | PASS | PASS | Atomic provisioning workflow creates database row, executes isolated migration scripts, and seeds initial Tenant Owner account. |
| **US04** | PASS | PASS | PASS | PASS | PASS | PASS | Product master handles variant matrix (OptionGroup → OptionValues). Enforces `tenant_id` unique index on SKU codes. |
| **US05** | PASS | PASS | PASS | PASS | PASS | PASS | Fast filtering indexed by `(tenant_id, category_id, status)`. Returns facet counts for active filters. |
| **US06** | PASS | PASS | PASS | PASS | PASS | PASS | Barcode validation (EAN-13, UPC-A, Code 128). Uniqueness guaranteed per tenant scope. |
| **US07** | PASS | PASS | PASS | PASS | PASS | PASS | Total allocated stock across channels cannot exceed total available physical stock. Transactional consistency guaranteed. |
| **US08** | PASS | PASS | PASS | PASS | PASS | PASS | Redis distributed lock (Redlock) or DB pessimistic row lock (`FOR UPDATE`). Reservation record holds 15-minute TTL with auto-release background job. |
| **US09** | PASS | PASS | PASS | PASS | PASS | PASS | Safety stock threshold dynamically subtracted from total channel availability: `AvailableToSell = AllocatedStock - SafetyBuffer`. |
| **US10** | PASS | PASS | PASS | PASS | PASS | PASS | B2B buyer accounts contain credit limit, current outstanding balance, and payment terms (e.g. Net 30, Net 60). |
| **US11** | PASS | PASS | PASS | PASS | PASS | PASS | Volume tiers evaluated at cart calculation time: selects the lowest qualified unit price for the line item quantity. |
| **US12** | PASS | PASS | PASS | PASS | PASS | PASS | Synchronous validation bounded at 2,000 line items and 5 MB file size. Returns line-by-line validation errors before final commit. |
| **US13** | PASS | PASS | PASS | PASS | PASS | PASS | In-memory cart cached with optimistic concurrency control. Sub-10ms response time for cart modifications. |
| **US14** | PASS | PASS | PASS | PASS | PASS | PASS | `Idempotency-Key` header enforced on POST `/checkout`. Duplicate submissions within 24 hours replay previous successful order response. |
| **US15** | PASS | PASS | PASS | PASS | PASS | PASS | Validates `X-OmniTenant-Signature` using HMAC SHA-256 with tenant webhook secret. Replay protection via timestamp window (±5 minutes). |
| **US16** | PASS | PASS | PASS | PASS | PASS | PASS | Append-only audit log table. Captures `tenant_id`, `actor_id`, `action`, `resource`, `correlation_id`, `client_ip`, and delta snapshot. |
| **US17** | PASS | PASS | PASS | PASS | PASS | PASS | Role assignments validated via ASP.NET Core authorization policies (`[Authorize(Policy = "...")]`). Forbidden actions return 403. |
| **US18** | PASS | PASS | PASS | PASS | PASS | PASS | Outbound webhook dispatcher implements exponential backoff retry (3 attempts) with dead-letter logging upon repeated failure. |
| **US19** | PASS | PASS | PASS | PASS | PASS | PASS | Multimodal Vision + LLM pipeline extracts line items from images/PDFs. Fuzzy/vector matches against tenant SKUs; flags low-confidence items (<80%) for human confirmation. |
| **US20** | PASS | PASS | PASS | PASS | PASS | PASS | Scheduled analytics worker calculates rolling 30-day velocity. Predicts depletion dates and generates auto-draft replenishment POs with configurable lead time. |
| **US21** | PASS | PASS | PASS | PASS | PASS | PASS | Autonomous Revenue Agent identifies stagnant inventory (>30 days, velocity drop >50%). Calculates price elasticity, suggests clearance discounts, and provides one-click flash sale deployment. |

---

## Cross-cutting acceptance constraints

1. **Multi-Tenant Row-Level Segregation**:
   - All tenant queries are automatically scoped using global query filters or PostgreSQL Row-Level Security (`tenant_id = current_setting('app.current_tenant_id')`).
   - Cross-tenant lookups strictly yield `404 Not Found` to prevent entity enumeration.
2. **Concurrency & Zero Overselling**:
   - Inventory decrements must never produce a negative available balance under concurrent load.
   - High-concurrency checkout paths utilize distributed Redis locks (`redlock`) with fallback to database pessimistic locks (`SELECT ... FOR UPDATE`).
3. **Idempotency Standards**:
   - Mutating commerce endpoints (`/api/v1/checkout`, `/api/v1/webhooks/*`) mandate an `Idempotency-Key` header (UUID v4).
   - Results are cached in Redis with a 24-hour expiration window.
4. **Webhook Security**:
   - All external inbound payloads are verified via HMAC SHA-256 signatures before parsing.
   - Outbound webhooks include signed headers enabling customer verification.
5. **Standardized Error Handling**:
   - All API error responses strictly conform to **RFC 7807 ProblemDetails** with structured `type`, `title`, `status`, `detail`, and `instance` attributes.
6. **Distributed Tracing & Auditing**:
   - All requests carry an `X-Correlation-ID` header propagated across service boundaries and logged in all audit records.

---

**Related:** [Actors, roles, and use cases](03-use-cases.md) · [Acceptance criteria](06-acceptance-criteria.md)
