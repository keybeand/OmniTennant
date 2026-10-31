# Acceptance Criteria — OmniTenant V1

> Design status: TARGET V1
>
> Implementation status: TARGET SPECIFICATION

These criteria define the observable, testable conditions of success for all V1 use cases and user stories in OmniTenant. Automated integration tests and end-to-end test suites validate these criteria across multi-tenant boundaries.

---

## AC-UC01 — Global Login (Platform SuperAdmin)

- Valid root credentials and valid TOTP MFA code return a signed Platform Bearer JWT (15-minute expiration) and the platform administrator profile.
- Missing, invalid, or expired MFA codes return `401 Unauthorized` without disclosing credential validity.
- 5 consecutive failed login attempts trigger a 15-minute temporary lockout for the root account with security audit event logging.
- Protected platform endpoints reject requests lacking `platform:superadmin` claim with `403 Forbidden`.

---

## AC-UC02 — Provision Tenant

- Specifying a unique organization name, valid slug, domain alias, and primary owner email provisions an isolated tenant environment with HTTP status `201 Created`.
- The provisioning workflow initializes the tenant database schema, applies database migrations, seeds standard role definitions, and creates the Tenant Owner account.
- Submitting an existing slug or domain returns `409 Conflict` with a descriptive RFC 7807 `ProblemDetails` response.
- An activation email containing a single-use cryptographically signed activation token is dispatched to the owner email.

---

## AC-UC03 — Manage Global Subscriptions

- Platform SuperAdmin can view current tenant resource consumption metrics (SKU count, monthly API requests, active staff seats, storage usage).
- Upgrading or downgrading a tenant subscription tier commits immediately and returns `200 OK`.
- When a tenant exceeds resource quota limits (e.g. SKU quota), creation of new resources returns `422 Unprocessable Entity` with reason code `QUOTA_EXCEEDED`.

---

## AC-UC04 — Audit Platform Logs

- Platform SuperAdmin can query the immutable audit trail filtered by tenant ID, actor ID, action type, and date range with sub-second response times.
- Audit records contain timestamp (UTC), correlation ID, actor identity, action name, resource ID, IP address, and JSON diff of changes (with passwords and API secrets redacted).
- Attempted mutations to the audit log table (UPDATE or DELETE) are prevented at the database trigger level and raise an alert.

---

## AC-UC05 — Tenant Login & Switch

- Valid tenant user credentials return a Bearer JWT containing claims for `tenant_id`, `user_id`, and assigned role.
- Tenant context is verified via the request host header (custom domain/subdomain) or explicit `X-Tenant-ID` header. Requests targeting an inactive or suspended tenant return `403 Forbidden`.
- Users belonging to multiple tenants can exchange a valid session token via the tenant-switch endpoint to receive a new JWT scoped to the chosen `tenant_id`.

---

## AC-UC06 — Manage Tenant Users & RBAC

- Tenant Owner can invite staff members by email with assigned roles (`TENANT_OWNER`, `WAREHOUSE_OPERATOR`, `STAFF_VIEWER`).
- Users can be deactivated or have roles updated by Tenant Owner; changes take effect immediately on subsequent API requests.
- Staff members cannot access resources outside their tenant scope; cross-tenant ID references return `404 Not Found`.

---

## AC-UC07 — Configure Storefront & Webhooks

- Tenant Owner can save storefront branding parameters (logo URL, primary color hex, title, currency).
- Registering an outbound webhook endpoint requires a valid HTTPS URL and generates a cryptographically secure HMAC SHA-256 secret.
- Testing the webhook sends a ping event with header `X-OmniTenant-Signature`; successful acknowledgment returns `200 OK`.

---

## AC-UC08 — View Aggregated Analytics

- Tenant Owner can view sales revenue, order volumes, average order value (AOV), low-stock warnings, and channel allocation distributions.
- Warehouse Operator can view inventory KPIs (stock levels, out-of-stock items, safety buffer alerts) but cannot view financial profit/revenue metrics (`403 Forbidden`).
- Analytics queries execute against read-optimized views and complete in < 500ms.

---

## AC-UC09 — Manage Price Tiers

- Tenant Owner can create custom pricing tiers (e.g., "Wholesale Tier 1", "VIP Distributor") with volume discount breaks (e.g., 50+ units = 15% off).
- Minimum Order Quantities (MOQ) and tiered price rules can be scoped per SKU or across product categories.
- Overlapping tier quantity ranges are rejected server-side with validation error `400 Bad Request`.

---

## AC-UC10 — Manage Catalog & SKUs

- Tenant Owner and Warehouse Operator can create, update, and archive products and SKU variants.
- SKU codes must be unique within the tenant scope; duplicate SKU codes return `409 Conflict`.
- Deleting a product with active historical order lines performs a soft-delete (`archived_at` timestamp), retaining data for reporting and historical audit.

---

## AC-UC11 — Adjust Safety Stock

- Warehouse Operator can set a minimum safety stock threshold per SKU and channel.
- Setting the safety stock buffer higher than total physical stock returns a `400 Bad Request` confirmation warning.
- When available channel stock falls below the safety buffer, the system automatically marks the item as "Low Stock" and emits an `InventoryThresholdBreached` event.

---

## AC-UC12 — Allocate Channel Inventory

- Total stock allocated across all digital channels (B2C Storefront, B2B Wholesale, External Marketplaces) plus safety reserve cannot exceed total unallocated physical warehouse stock.
- Channel allocation updates execute within an atomic database transaction. If the requested allocation exceeds available physical stock, the transaction rolls back with `422 Unprocessable Entity`.
- Successful allocation immediately updates the public channel storefront availability.

---

## AC-UC13 — Ingest Inventory Webhook

- Inbound external WMS webhook requests must supply a valid `X-OmniTenant-Signature` (HMAC SHA-256) and timestamp within ±5 minutes.
- Invalid HMAC signatures or expired timestamps return `401 Unauthorized` without modifying state.
- Inbound requests must include an `Idempotency-Key` header; re-sending the same key returns the previous response with no duplicate stock adjustments.
- Concurrent inventory webhooks for the same SKU acquire a distributed Redis lock to prevent lost-update race conditions.

---

## AC-UC14 — Resolve Sync Conflicts

- System detects and flags discrepancies when external reported physical stock differs from tracked system stock by more than a configurable tolerance.
- Conflict queue displays SKU, reported external count, calculated internal balance, and discrepancy delta.
- Applying a reconciliation choice updates the stock ledger, records the resolution actor, and logs an immutable adjustment audit entry.

---

## AC-UC15 — Browse Catalog & Prices

- Public visitors view MSRP retail pricing; authenticated B2B Buyers automatically see their assigned contract tier pricing and active volume breaks.
- Products marked as out of stock display "Out of Stock" and disable the direct add-to-cart trigger unless backordering is explicitly enabled.
- Catalog searches with faceted filters return results within 200ms under 100 concurrent requests.

---

## AC-UC16 — Reserve Stock & Checkout

- Checkout requests mandate an `Idempotency-Key` header. Duplicate requests with the same key return the original order confirmation without duplicate payment or reservation.
- Inventory reservation uses a distributed lock (Redis Redlock or DB row lock); stock is decremented atomically with a 15-minute temporary reservation TTL.
- If requested quantity exceeds channel available-to-sell stock on any line item, the entire reservation fails with `409 Conflict`, listing specific unavailable SKUs.
- If payment fails or times out within 15 minutes, a background reaper releases the reserved stock back to the channel pool.

---

## AC-UC17 — Track Order & Invoices

- Customers can track real-time order status (Payment Pending, Allocated, Picked, Shipped, Delivered) using their order ID.
- Access to order details is strictly restricted to the order owner or authorized tenant staff; unauthorized access returns `404 Not Found`.
- Generating an invoice produces a standardized PDF containing itemized line totals, applied volume discounts, tax breakdown, and company billing info.

---

## AC-UC18 — Bulk Order Upload (B2B)

- B2B Buyers can upload `.csv` or `.xlsx` files containing up to 2,000 order lines and 5 MB maximum size.
- Server validates each line item (SKU existence, minimum order quantity, stock availability, and tier pricing) before committing.
- Returns a structured validation summary: total lines, valid lines, and a list of invalid rows with specific error messages.
- Confirming an approved upload atomically creates the wholesale draft order and reserves corresponding inventory.

---

## AC-UC19 — AI-Driven B2B PO Parsing (Snap-to-Order)

- Supports multi-format ingest: PNG, JPEG, WebP images of handwritten notes/paper receipts, multi-page PDFs, and raw text order messages up to 10 MB.
- AI pipeline extracts line items, quantities, and optional notes; parses within $\le 5$ seconds under normal load.
- Product matching resolves noisy human text to tenant catalog SKUs scoped strictly to `tenant_id` (cross-tenant matching is structurally impossible).
- Returns structured JSON response with per-line confidence scores ($0.00 - 1.00$):
  - Items with confidence $\ge 0.80$ are marked `AUTO_MATCHED`.
  - Items with confidence $< 0.80$ or ambiguous matches are marked `NEEDS_REVIEW` with top 3 alternative SKU suggestions.
- Automatically applies B2B tiered volume pricing for matched quantities and evaluates real-time channel stock.
- Confirmed draft order transitions to standard checkout pipeline respecting `Idempotency-Key` and two-phase stock locking.

---

## AC-UC20 — Autonomous AI Inventory Copilot & Forecasting

- Calculates rolling 30-day sales velocity and consumption rates across all sales channels per SKU.
- Dynamically predicts "Runway Days" (time to stockout): $\text{Runway} = \frac{\text{AvailableStock}}{\text{DailyBurnRate}}$.
- Automatically triggers high-priority replenishment alert when $\text{Runway} \le \text{SupplierLeadTime} + \text{SafetyBuffer}$.
- Suggests optimal reorder quantity: $\text{ReorderQty} = (\text{TargetRunwayDays} \times \text{DailyBurnRate}) - \text{AvailableStock}$.
- All forecast records and suggestions are stored in `ai_inventory_forecasts` with PostgreSQL RLS isolation.
- Approving a recommendation atomically generates a supplier Purchase Order (PO) and dispatches an outbound webhook event `inventory.reorder_approved`.

---

**Related:** [Actors, roles, and use cases](03-use-cases.md) · [INVEST Requirements](08-invest-requirements.md)
