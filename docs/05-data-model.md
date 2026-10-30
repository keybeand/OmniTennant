# Data Model (PostgreSQL Schema Design) — OmniTenant V1

> Design status: TARGET V1
>
> Runtime status: TARGET SCHEMA SPECIFICATION

Product name: **OmniTenant**.

This document specifies the PostgreSQL data model designed to support cloud-native multi-tenant B2B/B2C commerce, high-concurrency stock reservation, omnichannel inventory allocation, and row-level tenant data segregation.

Related sources of truth: [DATABASE.md](DATABASE.md) · [schema.sql](../src/database/schema.sql) · [04-information-architecture.md](04-information-architecture.md).

---

## 1. Tables Overview

| Table | Domain / Purpose | Key Columns & Characteristics |
|---|---|---|
| `tenants` | Platform Multi-Tenancy | `id` (UUID PK), `name`, `slug` (unique), `domain_cname`, `subscription_tier`, `status`, `settings` (JSONB). Root tenant entity. |
| `app_users` | Identity & RBAC | `id` (UUID PK), `tenant_id` (FK nullable for SuperAdmin), `email`, `password_hash`, `full_name`, `role`, `is_active`, `deleted_at`. |
| `b2b_customer_profiles` | B2B Commercial Enablement | `id` (UUID PK), `tenant_id` (FK), `user_id` (FK), `company_name`, `tax_id`, `credit_limit`, `current_balance`, `payment_terms`, `approval_status`. |
| `categories` | Product Taxonomy | `id` (UUID PK), `tenant_id` (FK), `parent_id` (Self FK for trees), `name`, `slug`, `display_order`, `is_active`. |
| `products` | Product Catalog Master | `id` (UUID PK), `tenant_id` (FK), `category_id` (FK), `title`, `slug`, `description`, `base_price`, `status`, `deleted_at`. |
| `skus` | Variant Units & Barcodes | `id` (UUID PK), `tenant_id` (FK), `product_id` (FK), `sku_code` (unique per tenant), `barcode`, `attributes` (JSONB: size, color), `weight_grams`, `cost_price`, `retail_price`. |
| `price_tiers` | B2B Wholesale Pricing | `id` (UUID PK), `tenant_id` (FK), `name`, `currency_code`, `description`. Defines commercial customer groups. |
| `tier_volume_rules` | Volume Break Matrix | `id` (UUID PK), `tenant_id` (FK), `price_tier_id` (FK), `sku_id` (FK nullable), `category_id` (FK nullable), `min_quantity` (MOQ), `max_quantity`, `discount_type`, `unit_price`, `discount_value`. |
| `b2b_buyer_tier_assignments`| Buyer-to-Tier Mapping | `user_id` (FK), `price_tier_id` (FK), `tenant_id` (FK). Composite PK `(user_id, price_tier_id)`. |
| `warehouses` | Physical Fulfillment Locations | `id` (UUID PK), `tenant_id` (FK), `name`, `code`, `address` (JSONB). |
| `inventory_physical_stock` | Physical Warehouse Counts | `id` (UUID PK), `tenant_id` (FK), `warehouse_id` (FK), `sku_id` (FK), `total_physical_quantity`, `last_counted_at`, `version` (xmin / lock). |
| `inventory_channel_allocations` | Omnichannel Quotas | `id` (UUID PK), `tenant_id` (FK), `sku_id` (FK), `channel` (B2C, B2B, Retail), `allocated_quantity`, `safety_stock_buffer`, `version` (int optimistic lock). |
| `inventory_reservations` | Concurrency Hold (TTL 15m) | `id` (UUID PK), `tenant_id` (FK), `sku_id` (FK), `channel`, `cart_or_session_id`, `quantity`, `expires_at`, `status` (HELD, COMMITTED, EXPIRED, CANCELLED). |
| `inventory_sync_conflicts` | Discrepancy Reconciliation | `id` (UUID PK), `tenant_id` (FK), `sku_id` (FK), `warehouse_id` (FK), `reported_delta`, `system_balance`, `discrepancy`, `status`, `resolution_notes`, `resolved_by`. |
| `orders` | Commerce Transactions | `id` (UUID PK), `tenant_id` (FK), `order_number` (unique), `customer_id` (FK), `channel`, `order_type`, `status`, `payment_method`, `subtotal`, `tax_amount`, `discount_amount`, `total_amount`, `idempotency_key`, `shipping_address` (JSONB). |
| `order_items` | Itemized Order Lines | `id` (UUID PK), `tenant_id` (FK), `order_id` (FK), `sku_id` (FK), `sku_code`, `product_title`, `quantity`, `unit_price`, `line_total`, `applied_tier_rule_id`. |
| `b2b_bulk_order_batches` | Asynchronous Order Ingestion | `id` (UUID PK), `tenant_id` (FK), `buyer_id` (FK), `file_name`, `total_rows`, `valid_rows`, `failed_rows`, `status`, `error_summary` (JSONB). |
| `webhook_endpoints` | Event Integrations | `id` (UUID PK), `tenant_id` (FK), `url`, `signing_secret` (HMAC SHA-256), `subscribed_events` (text array), `is_active`. |
| `audit_logs` | Immutable Compliance Ledger | `id` (UUID PK), `tenant_id` (FK nullable), `actor_id` (FK), `actor_email`, `action`, `entity_type`, `entity_id`, `correlation_id`, `client_ip`, `diff` (JSONB redacted), `created_at`. |

---

## 2. Multi-Tenant Row-Level Security (RLS) Strategy

To eliminate cross-tenant data leakage, all business tables enforce **PostgreSQL Row-Level Security** directly within the database engine.

1. **Session Tenant Binding:** When an API request is authenticated, the backend database connection sets a local session parameter:
   ```sql
   SET LOCAL app.current_tenant_id = 'c0a80123-0000-0000-0000-000000000001';
   SET LOCAL app.is_superadmin = 'false';
   ```
2. **Standard RLS Policy Formulation:**
   ```sql
   ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
   
   CREATE POLICY tenant_isolation_policy ON orders
   AS RESTRICTIVE
   USING (
       current_setting('app.is_superadmin', true) = 'true'
       OR tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::uuid
   );
   ```
3. **Fail-Safe Mechanism:** If an unauthenticated or misconfigured query executes without setting `app.current_tenant_id`, the expression evaluates to `NULLIF('', '')` $\rightarrow$ `NULL`, which evaluates to `FALSE` for all rows. Zero rows are returned or mutated.

---

## 3. High-Concurrency Stock Reservation & Locking Model

Overselling is prevented through a **Two-Tier Locking & Concurrency Model**:

```
                       [Incoming Checkout Request]
                                    │
                         Tier 1: Redis Distributed Lock
                     (Redlock on SKU key for ~10-20ms)
                                    │
                                    ▼
                     Tier 2: Optimistic Versioning (PostgreSQL)
               UPDATE inventory_channel_allocations
               SET allocated_quantity = allocated_quantity - :qty,
                   version = version + 1
               WHERE sku_id = :skuId 
                 AND channel = :channel
                 AND version = :expectedVersion
                 AND (allocated_quantity - safety_stock_buffer) >= :qty;
                                    │
                         ┌──────────┴──────────┐
                 [Rows Updated = 1]     [Rows Updated = 0]
                         │                     │
                         ▼                     ▼
               Insert Reservation Hold     Return 409 Conflict
               (TTL 15 min, Status: HELD)  (Release Redis Lock)
```

1. **Available-To-Sell (ATS) Calculation:**
   $$\text{ATS} = \text{allocated\_quantity} - \text{safety\_stock\_buffer}$$
2. **Two-Phase Commit Semantics:**
   * **Phase 1 (Reserve):** Stock is decremented from `allocated_quantity` and recorded in `inventory_reservations` with `status = 'HELD'` and `expires_at = NOW() + INTERVAL '15 minutes'`.
   * **Phase 2 (Commit):** Payment succeeds $\rightarrow$ Reservation marked `COMMITTED`, order transitions to `PAID`.
   * **Phase 2 (Rollback):** Payment fails or time exceeds 15 minutes $\rightarrow$ Background reaper job updates reservation to `EXPIRED` and atomically credits `allocated_quantity` back to the channel pool.

---

## 4. Soft Delete Policy & Audit Security

### Soft Delete Implementation
- Tables supporting soft deletion: `app_users`, `products`, `categories`.
- Query filtering: Active entity queries enforce `WHERE deleted_at IS NULL`.
- Audit semantics: Soft deletion is persisted via an SQL `UPDATE` setting `deleted_at = NOW()`, but the audit trail records the high-level business action as `SOFT_DELETE`. Restoring an archived record records `RESTORE`.
- Deleting products with historical order lines is restricted to soft deletion; hard `CASCADE DELETE` is forbidden on transactional tables.

### Audit Security & PII Redaction (`SEC-AUDIT-001`)
- The `audit_logs.diff` JSONB column records entity snapshots for compliance.
- Database triggers and application interceptors **strictly redact sensitive fields** before persisting audit snapshots:
  * `password_hash`, `totp_secret`, `signing_secret` $\rightarrow$ Replaced with `"[REDACTED]"`.
  * Credit card tokens or API credentials are never written to audit tables.

---

## 5. Transaction Boundaries

| Business Workflow | Transaction Scope & Boundary Rules | Rollback & Failure Behavior |
|---|---|---|
| **Tenant Provisioning** | Inserts `tenants` record, seeds default `categories`, creates initial `warehouses`, and seeds Tenant Owner `app_users` in one transaction. | Any collision or failure rolls back all records; no orphaned tenant data. |
| **B2C / B2B Checkout** | Validates `idempotency_key`, decrements channel stock, creates `inventory_reservations`, and inserts `orders` + `order_items`. | Insufficient stock on any item immediately aborts the transaction (`409 Conflict`); zero partial reservations. |
| **B2B Bulk CSV Import** | Bounded at 2,000 line items and 5 MB. Validates all rows in memory; batch insert of draft order lines executed in a single transaction. | Any critical data corruption rolls back entire batch insertion; error report returned to client. |
| **WMS Webhook Delta** | Ingests external inventory delta, validates HMAC signature, updates `inventory_physical_stock`, updates `inventory_channel_allocations`, and creates audit log. | Duplicate `idempotency_key` replays original cached response without re-executing inventory mutations. |
| **Inventory Reconciliation** | Applies stock correction to `inventory_physical_stock`, adjusts safety stock or channel allocations, marks conflict `RESOLVED`, and logs audit trail. | Atomic; ensures physical count and channel allocations balance. |

---

## 6. Analytical Views (Reporting Design)

To provide sub-second dashboard performance without blocking transactional writes, read-optimized views are defined:

1. **`vw_storefront_catalog`**: Joins `products`, `categories`, and `skus` with active channel stock and base retail prices.
2. **`vw_stock_health_alerts`**: Computes `available_to_sell` and flags SKUs where `allocated_quantity <= safety_stock_buffer` with alert status `CRITICAL` or `DEPLETED`.
3. **`vw_b2b_credit_risk`**: Evaluates corporate buyer credit utilization: `(current_balance / credit_limit) * 100`, highlighting accounts exceeding 80% utilization.
4. **`vw_sales_summary_daily`**: Aggregates gross revenue, order count, and average order value (AOV) grouped by `tenant_id`, `channel`, and `DATE(created_at)`.

---

## 7. Currency & Pricing Standards

- **Internal Base Currency:** Stored as `NUMERIC(14, 2)`. Default tenant currency is stored in `tenants.settings->>'currency'` (e.g. `USD`, `VND`, `EUR`).
- **Exchange Conversions:** Multi-currency display on the storefront is computed at presentation time; transactional balances in the database remain pinned to the tenant base currency.
- **Tiered Volume Evaluation:** Evaluated dynamically at cart calculation using the lowest qualifying unit price matching `min_quantity <= requested_qty <= max_quantity`.

---

**Related:** [Data Diagram & ERD](DATABASE.md) · [Database Schema DDL](../src/database/schema.sql) · [Use Cases](03-use-cases.md)
