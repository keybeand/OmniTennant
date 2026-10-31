# Data Diagram & Entity Relationships — OmniTenant V1

> Design status: TARGET V1
>
> Runtime status: TARGET SCHEMA SPECIFICATION

PostgreSQL schema for **OmniTenant**.

This document outlines the entity relationships, relational cardinality, enumerated data types, database reporting views, and comprehensive ER diagrams for the platform.

Design files: [schema.sql](../src/database/schema.sql) · [05-data-model.md](05-data-model.md) · [04-information-architecture.md](04-information-architecture.md).

---

## 1. Domain Group Relationships

The architecture isolates entities into 6 cohesive domains. Every domain entity is strictly bound to its parent `tenants` organization.

```mermaid
%%{init: {"flowchart": {"nodeSpacing": 30, "rankSpacing": 70, "padding": 12}}}%%
flowchart LR
    T[tenants]

    subgraph identityGroup [Identity & RBAC]
        direction TB
        U[app_users]
        B2BP[b2b_customer_profiles]
    end

    subgraph catalogGroup [Catalog & Variants]
        direction TB
        CAT[categories]
        P[products]
        SKU[skus]
    end

    subgraph pricingGroup [Wholesale Pricing]
        direction TB
        PT[price_tiers]
        TVR[tier_volume_rules]
    end

    subgraph inventoryGroup [Omnichannel Inventory]
        direction TB
        WH[warehouses]
        IPS[inventory_physical_stock]
        ICA[inventory_channel_allocations]
        RES[inventory_reservations]
        CONF[inventory_sync_conflicts]
    end

    subgraph commerceGroup [Commerce & Orders]
        direction TB
        O[orders]
        OI[order_items]
        BAT[b2b_bulk_order_batches]
    end

    subgraph sharedGroup [Shared & Integration]
        direction TB
        WHK[webhook_endpoints]
        AUD[audit_logs]
    end

    subgraph aiGroup [AI Automation & Intelligence]
        direction TB
        AIPO[ai_po_parse_jobs]
        AIFC[ai_inventory_forecasts]
    end

    T --> identityGroup
    T --> catalogGroup
    T --> pricingGroup
    T --> inventoryGroup
    T --> commerceGroup
    T --> sharedGroup
    T --> aiGroup

    U --> B2BP
    CAT --> P --> SKU
    PT --> TVR
    WH --> IPS
    SKU --> IPS
    SKU --> ICA
    SKU --> RES
    O --> OI
    SKU --> OI
    SKU --> AIFC
    O -.-> AIPO
```

---

## 2. Enumerated Types (Enums)

| Enum Type | Allowed Values | Usage & Business Context |
|---|---|---|
| `subscription_tier` | `FREE`, `PRO`, `ENTERPRISE` | Tenant resource quota and platform feature gating. |
| `tenant_status` | `ACTIVE`, `SUSPENDED`, `ARCHIVED` | Tenant organization operational lifecycle state. |
| `user_role` | `SUPERADMIN`, `TENANT_OWNER`, `WAREHOUSE_OPERATOR`, `B2B_BUYER`, `B2C_SHOPPER` | Role-based access control (RBAC) authorization level. |
| `b2b_approval_status`| `PENDING`, `APPROVED`, `REJECTED`, `SUSPENDED` | Corporate buyer credit line verification status. |
| `b2b_payment_terms` | `PREPAID`, `NET_15`, `NET_30`, `NET_60` | Agreed B2B credit settlement terms. |
| `product_status` | `DRAFT`, `PUBLISHED`, `ARCHIVED` | Lifecycle visibility on storefront catalog. |
| `sales_channel` | `ONLINE_B2C`, `WHOLESALE_B2B`, `RETAIL_OUTLET` | Dedicated inventory allocation quota channel. |
| `discount_type` | `PERCENTAGE`, `FIXED_PRICE` | Calculation rule for tiered wholesale volume breaks. |
| `reservation_status`| `HELD`, `COMMITTED`, `EXPIRED`, `CANCELLED` | Two-phase checkout temporary stock hold lifecycle. |
| `conflict_status` | `OPEN`, `RESOLVED`, `IGNORED` | External WMS stock discrepancy resolution status. |
| `order_status` | `PENDING_PAYMENT`, `RESERVED`, `PAID`, `ALLOCATED`, `SHIPPED`, `DELIVERED`, `CANCELLED` | Commercial order progression state. |
| `order_type` | `RETAIL`, `B2B_PURCHASE_ORDER` | Direct retail cart checkout vs. corporate PO checkout. |
| `payment_method` | `CREDIT_CARD`, `B2B_CREDIT_TERMS`, `BANK_TRANSFER`, `CASH_ON_DELIVERY` | Settlement method recorded on order. |
| `audit_action` | `CREATE`, `UPDATE`, `SOFT_DELETE`, `RESTORE`, `RECONCILE`, `CREDIT_OVERRIDE`, `LOGIN` | Business mutation taxonomy in compliance logs. |

---

## 3. Database Views (Analytical Aggregates)

Views provide pre-aggregated reporting metrics and read-optimized models without locking active transactional rows:

```mermaid
flowchart LR
    P[products] --> V1[vw_storefront_catalog]
    SKU[skus] --> V1
    ICA[inventory_channel_allocations] --> V1
    
    ICA --> V2[vw_stock_health_alerts]
    SKU --> V2
    
    B2BP[b2b_customer_profiles] --> V3[vw_b2b_credit_risk]
    
    O[orders] --> V4[vw_sales_summary_daily]
    OI[order_items] --> V4
```

---

## 4. Comprehensive Entity-Relationship Diagram (ERD)

```mermaid
erDiagram
    tenants ||--o{ app_users : "employs / owns"
    tenants ||--o{ categories : "manages"
    tenants ||--o{ products : "sells"
    tenants ||--o{ skus : "catalogs"
    tenants ||--o{ price_tiers : "configures"
    tenants ||--o{ warehouses : "operates"
    tenants ||--o{ orders : "fulfills"
    tenants ||--o{ webhook_endpoints : "registers"
    tenants ||--o{ audit_logs : "records"

    app_users ||--o| b2b_customer_profiles : "extends corporate info"
    app_users ||--o{ orders : "places"
    app_users ||--o{ b2b_buyer_tier_assignments : "assigned to"

    categories ||--o{ categories : "sub-category tree"
    categories ||--o{ products : "classifies"

    products ||--o{ skus : "has variants"

    price_tiers ||--o{ tier_volume_rules : "defines breaks"
    price_tiers ||--o{ b2b_buyer_tier_assignments : "contains buyers"
    skus ||--o{ tier_volume_rules : "targeted by"

    warehouses ||--o{ inventory_physical_stock : "stores"
    skus ||--o{ inventory_physical_stock : "counted in"

    skus ||--o{ inventory_channel_allocations : "allocated across"
    skus ||--o{ inventory_reservations : "temporarily held"
    skus ||--o{ inventory_sync_conflicts : "flags discrepancies"

    orders ||--o{ order_items : "contains"
    skus ||--o{ order_items : "purchased as"

    tenants {
        uuid id PK
        varchar slug UK
        varchar name
        varchar domain_cname
        subscription_tier subscription_tier
        tenant_status status
        jsonb settings
        timestamptz created_at
        timestamptz updated_at
    }

    app_users {
        uuid id PK
        uuid tenant_id FK
        varchar email
        varchar password_hash
        varchar full_name
        varchar phone
        user_role role
        boolean is_active
        timestamptz deleted_at
        timestamptz last_login_at
    }

    b2b_customer_profiles {
        uuid id PK
        uuid tenant_id FK
        uuid user_id FK
        varchar company_name
        varchar tax_id
        numeric credit_limit
        numeric current_balance
        b2b_payment_terms payment_terms
        b2b_approval_status approval_status
    }

    categories {
        uuid id PK
        uuid tenant_id FK
        uuid parent_id FK
        varchar name
        varchar slug
        integer display_order
        boolean is_active
        timestamptz deleted_at
    }

    products {
        uuid id PK
        uuid tenant_id FK
        uuid category_id FK
        varchar title
        varchar slug
        text description
        numeric base_price
        product_status status
        timestamptz deleted_at
    }

    skus {
        uuid id PK
        uuid tenant_id FK
        uuid product_id FK
        varchar sku_code UK
        varchar barcode
        jsonb attributes
        integer weight_grams
        numeric cost_price
        numeric retail_price
        boolean is_active
    }

    price_tiers {
        uuid id PK
        uuid tenant_id FK
        varchar name
        char currency_code
        text description
    }

    tier_volume_rules {
        uuid id PK
        uuid tenant_id FK
        uuid price_tier_id FK
        uuid sku_id FK
        integer min_quantity
        integer max_quantity
        discount_type discount_type
        numeric unit_price
        numeric discount_value
    }

    warehouses {
        uuid id PK
        uuid tenant_id FK
        varchar name
        varchar code
        jsonb address
    }

    inventory_physical_stock {
        uuid id PK
        uuid tenant_id FK
        uuid warehouse_id FK
        uuid sku_id FK
        integer total_physical_quantity
        timestamptz last_counted_at
        integer version
    }

    inventory_channel_allocations {
        uuid id PK
        uuid tenant_id FK
        uuid sku_id FK
        sales_channel channel
        integer allocated_quantity
        integer safety_stock_buffer
        integer version
    }

    inventory_reservations {
        uuid id PK
        uuid tenant_id FK
        uuid sku_id FK
        sales_channel channel
        uuid cart_or_session_id
        integer quantity
        reservation_status status
        timestamptz expires_at
    }

    orders {
        uuid id PK
        uuid tenant_id FK
        varchar order_number UK
        uuid customer_id FK
        sales_channel channel
        order_type order_type
        order_status status
        payment_method payment_method
        numeric subtotal
        numeric tax_amount
        numeric discount_amount
        numeric total_amount
        uuid idempotency_key UK
        jsonb shipping_address
    }

    order_items {
        uuid id PK
        uuid tenant_id FK
        uuid order_id FK
        uuid sku_id FK
        varchar sku_code
        varchar product_title
        integer quantity
        numeric unit_price
        numeric line_total
    }

    audit_logs {
        uuid id PK
        uuid tenant_id FK
        uuid actor_id FK
        varchar actor_email
        audit_action action
        varchar entity_type
        varchar entity_id
        uuid correlation_id
        inet client_ip
        jsonb diff
        timestamptz created_at
    }

    ai_po_parse_jobs {
        uuid id PK
        uuid tenant_id FK
        uuid actor_id FK
        varchar status
        text file_url
        text raw_extracted_text
        jsonb parsed_items
        uuid matched_order_id FK
        numeric confidence_score
        text error_message
        timestamptz created_at
    }

    ai_inventory_forecasts {
        uuid id PK
        uuid tenant_id FK
        uuid sku_id FK
        numeric daily_burn_rate
        numeric runway_days
        integer suggested_reorder_qty
        varchar risk_level
        varchar status
        text notes
        timestamptz created_at
    }
```

---

**Related:** [Data Model Specification](05-data-model.md) · [Database Schema DDL](../src/database/schema.sql)
