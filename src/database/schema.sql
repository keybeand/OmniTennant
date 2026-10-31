-- ============================================================================
-- OmniTenant Platform Database Schema (PostgreSQL)
-- Target Version: V1
-- Features: Multi-Tenancy (RLS), Concurrency Locks, B2B Tiered Pricing,
--           Omnichannel Inventory Allocation, Idempotent Orders, Audit Trail.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ============================================================================
-- 1. ENUMERATED TYPES
-- ============================================================================

CREATE TYPE subscription_tier AS ENUM ('FREE', 'PRO', 'ENTERPRISE');
CREATE TYPE tenant_status AS ENUM ('ACTIVE', 'SUSPENDED', 'ARCHIVED');
CREATE TYPE user_role AS ENUM ('SUPERADMIN', 'TENANT_OWNER', 'WAREHOUSE_OPERATOR', 'B2B_BUYER', 'B2C_SHOPPER');
CREATE TYPE b2b_approval_status AS ENUM ('PENDING', 'APPROVED', 'REJECTED', 'SUSPENDED');
CREATE TYPE b2b_payment_terms AS ENUM ('PREPAID', 'NET_15', 'NET_30', 'NET_60');
CREATE TYPE product_status AS ENUM ('DRAFT', 'PUBLISHED', 'ARCHIVED');
CREATE TYPE sales_channel AS ENUM ('ONLINE_B2C', 'WHOLESALE_B2B', 'RETAIL_OUTLET');
CREATE TYPE discount_type AS ENUM ('PERCENTAGE', 'FIXED_PRICE');
CREATE TYPE reservation_status AS ENUM ('HELD', 'COMMITTED', 'EXPIRED', 'CANCELLED');
CREATE TYPE conflict_status AS ENUM ('OPEN', 'RESOLVED', 'IGNORED');
CREATE TYPE order_status AS ENUM ('PENDING_PAYMENT', 'RESERVED', 'PAID', 'ALLOCATED', 'SHIPPED', 'DELIVERED', 'CANCELLED');
CREATE TYPE order_type AS ENUM ('RETAIL', 'B2B_PURCHASE_ORDER');
CREATE TYPE payment_method AS ENUM ('CREDIT_CARD', 'B2B_CREDIT_TERMS', 'BANK_TRANSFER', 'CASH_ON_DELIVERY');
CREATE TYPE audit_action AS ENUM ('CREATE', 'UPDATE', 'SOFT_DELETE', 'RESTORE', 'RECONCILE', 'CREDIT_OVERRIDE', 'LOGIN');

-- ============================================================================
-- 2. CORE MULTI-TENANCY & IDENTITY TABLES
-- ============================================================================

-- Root Tenants Table (Global Scope)
CREATE TABLE tenants (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    slug VARCHAR(64) NOT NULL UNIQUE,
    name VARCHAR(255) NOT NULL,
    domain_cname VARCHAR(255) UNIQUE,
    subscription_tier subscription_tier NOT NULL DEFAULT 'FREE',
    status tenant_status NOT NULL DEFAULT 'ACTIVE',
    settings JSONB NOT NULL DEFAULT '{"currency": "USD", "brandColor": "#1168bd"}',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Users Table (SuperAdmin has tenant_id = NULL, tenant users scoped by tenant_id)
CREATE TABLE app_users (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
    email VARCHAR(255) NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    full_name VARCHAR(255) NOT NULL,
    phone VARCHAR(32),
    avatar_url TEXT,
    role user_role NOT NULL DEFAULT 'B2C_SHOPPER',
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    last_login_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ,
    CONSTRAINT uq_tenant_user_email UNIQUE (tenant_id, email)
);

-- B2B Customer Profiles Table (Corporate Accounts & Credit Limits)
CREATE TABLE b2b_customer_profiles (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    user_id UUID NOT NULL UNIQUE REFERENCES app_users(id) ON DELETE CASCADE,
    company_name VARCHAR(255) NOT NULL,
    tax_id VARCHAR(64) NOT NULL,
    credit_limit NUMERIC(14, 2) NOT NULL DEFAULT 0.00 CHECK (credit_limit >= 0),
    current_balance NUMERIC(14, 2) NOT NULL DEFAULT 0.00 CHECK (current_balance >= 0),
    payment_terms b2b_payment_terms NOT NULL DEFAULT 'PREPAID',
    approval_status b2b_approval_status NOT NULL DEFAULT 'PENDING',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================================
-- 3. CATALOG & SKU VARIANT TABLES
-- ============================================================================

-- Product Categories (Hierarchical tree)
CREATE TABLE categories (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    parent_id UUID REFERENCES categories(id) ON DELETE SET NULL,
    name VARCHAR(255) NOT NULL,
    slug VARCHAR(255) NOT NULL,
    display_order INT NOT NULL DEFAULT 0,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ,
    CONSTRAINT uq_tenant_category_slug UNIQUE (tenant_id, slug)
);

-- Products Master
CREATE TABLE products (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    category_id UUID REFERENCES categories(id) ON DELETE RESTRICT,
    title VARCHAR(255) NOT NULL,
    slug VARCHAR(255) NOT NULL,
    description TEXT,
    base_price NUMERIC(14, 2) NOT NULL CHECK (base_price >= 0),
    status product_status NOT NULL DEFAULT 'DRAFT',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ,
    CONSTRAINT uq_tenant_product_slug UNIQUE (tenant_id, slug)
);

-- SKU Variant Units
CREATE TABLE skus (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    product_id UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    sku_code VARCHAR(64) NOT NULL,
    barcode VARCHAR(64),
    attributes JSONB NOT NULL DEFAULT '{}',
    weight_grams INT DEFAULT 0,
    cost_price NUMERIC(14, 2) DEFAULT 0.00,
    retail_price NUMERIC(14, 2) NOT NULL CHECK (retail_price >= 0),
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_tenant_sku_code UNIQUE (tenant_id, sku_code)
);

-- ============================================================================
-- 4. WHOLESALE PRICING & TIERED VOLUME DISCOUNTS
-- ============================================================================

-- Pricing Tiers
CREATE TABLE price_tiers (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    name VARCHAR(128) NOT NULL,
    currency_code CHAR(3) NOT NULL DEFAULT 'USD',
    description TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Tier Volume Discount Break Matrix
CREATE TABLE tier_volume_rules (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    price_tier_id UUID NOT NULL REFERENCES price_tiers(id) ON DELETE CASCADE,
    sku_id UUID REFERENCES skus(id) ON DELETE CASCADE,
    category_id UUID REFERENCES categories(id) ON DELETE CASCADE,
    min_quantity INT NOT NULL CHECK (min_quantity >= 1),
    max_quantity INT CHECK (max_quantity IS NULL OR max_quantity >= min_quantity),
    discount_type discount_type NOT NULL DEFAULT 'PERCENTAGE',
    unit_price NUMERIC(14, 2) CHECK (unit_price IS NULL OR unit_price >= 0),
    discount_value NUMERIC(14, 2) NOT NULL CHECK (discount_value >= 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- B2B Buyer to Tier Mapping
CREATE TABLE b2b_buyer_tier_assignments (
    user_id UUID NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
    price_tier_id UUID NOT NULL REFERENCES price_tiers(id) ON DELETE CASCADE,
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    PRIMARY KEY (user_id, price_tier_id)
);

-- ============================================================================
-- 5. OMNICHANNEL INVENTORY & CONCURRENCY TABLES
-- ============================================================================

-- Physical Warehouses
CREATE TABLE warehouses (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    name VARCHAR(255) NOT NULL,
    code VARCHAR(32) NOT NULL,
    address JSONB NOT NULL DEFAULT '{}',
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_tenant_warehouse_code UNIQUE (tenant_id, code)
);

-- Physical Warehouse Stock Counts
CREATE TABLE inventory_physical_stock (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    warehouse_id UUID NOT NULL REFERENCES warehouses(id) ON DELETE RESTRICT,
    sku_id UUID NOT NULL REFERENCES skus(id) ON DELETE CASCADE,
    total_physical_quantity INT NOT NULL DEFAULT 0 CHECK (total_physical_quantity >= 0),
    last_counted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    version INT NOT NULL DEFAULT 1,
    CONSTRAINT uq_warehouse_sku_stock UNIQUE (warehouse_id, sku_id)
);

-- Channel Allocation Quotas & Safety Stock Buffer
CREATE TABLE inventory_channel_allocations (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    sku_id UUID NOT NULL REFERENCES skus(id) ON DELETE CASCADE,
    channel sales_channel NOT NULL,
    allocated_quantity INT NOT NULL DEFAULT 0 CHECK (allocated_quantity >= 0),
    safety_stock_buffer INT NOT NULL DEFAULT 0 CHECK (safety_stock_buffer >= 0),
    version INT NOT NULL DEFAULT 1,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_tenant_sku_channel UNIQUE (tenant_id, sku_id, channel)
);

-- Temporary Concurrency Reservations (Holds with TTL 15 min)
CREATE TABLE inventory_reservations (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    sku_id UUID NOT NULL REFERENCES skus(id) ON DELETE CASCADE,
    channel sales_channel NOT NULL,
    cart_or_session_id UUID NOT NULL,
    quantity INT NOT NULL CHECK (quantity > 0),
    status reservation_status NOT NULL DEFAULT 'HELD',
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Sync Conflicts & Reconciliation Queue
CREATE TABLE inventory_sync_conflicts (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    sku_id UUID NOT NULL REFERENCES skus(id) ON DELETE CASCADE,
    warehouse_id UUID NOT NULL REFERENCES warehouses(id) ON DELETE RESTRICT,
    reported_delta INT NOT NULL,
    system_balance INT NOT NULL,
    discrepancy INT NOT NULL,
    status conflict_status NOT NULL DEFAULT 'OPEN',
    resolution_notes TEXT,
    resolved_by UUID REFERENCES app_users(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    resolved_at TIMESTAMPTZ
);

-- ============================================================================
-- 6. COMMERCE, CHECKOUT & ORDERS
-- ============================================================================

-- Orders Table
CREATE TABLE orders (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    order_number VARCHAR(64) NOT NULL,
    customer_id UUID REFERENCES app_users(id) ON DELETE SET NULL,
    channel sales_channel NOT NULL DEFAULT 'ONLINE_B2C',
    order_type order_type NOT NULL DEFAULT 'RETAIL',
    status order_status NOT NULL DEFAULT 'PENDING_PAYMENT',
    payment_method payment_method NOT NULL DEFAULT 'CREDIT_CARD',
    subtotal NUMERIC(14, 2) NOT NULL DEFAULT 0.00,
    tax_amount NUMERIC(14, 2) NOT NULL DEFAULT 0.00,
    discount_amount NUMERIC(14, 2) NOT NULL DEFAULT 0.00,
    total_amount NUMERIC(14, 2) NOT NULL DEFAULT 0.00,
    idempotency_key UUID NOT NULL,
    shipping_address JSONB NOT NULL DEFAULT '{}',
    billing_address JSONB NOT NULL DEFAULT '{}',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_tenant_order_number UNIQUE (tenant_id, order_number),
    CONSTRAINT uq_tenant_order_idempotency UNIQUE (tenant_id, idempotency_key)
);

-- Order Line Items
CREATE TABLE order_items (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    order_id UUID NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    sku_id UUID NOT NULL REFERENCES skus(id) ON DELETE RESTRICT,
    sku_code VARCHAR(64) NOT NULL,
    product_title VARCHAR(255) NOT NULL,
    quantity INT NOT NULL CHECK (quantity > 0),
    unit_price NUMERIC(14, 2) NOT NULL CHECK (unit_price >= 0),
    line_total NUMERIC(14, 2) NOT NULL CHECK (line_total >= 0),
    applied_tier_rule_id UUID REFERENCES tier_volume_rules(id) ON DELETE SET NULL
);

-- B2B Bulk Order Upload Batches
CREATE TABLE b2b_bulk_order_batches (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    buyer_id UUID NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
    file_name VARCHAR(255) NOT NULL,
    total_rows INT NOT NULL DEFAULT 0,
    valid_rows INT NOT NULL DEFAULT 0,
    failed_rows INT NOT NULL DEFAULT 0,
    status VARCHAR(32) NOT NULL DEFAULT 'PROCESSING',
    error_summary JSONB NOT NULL DEFAULT '[]',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================================
-- 7. INTEGRATIONS & IMMUTABLE AUDIT TRAIL
-- ============================================================================

-- Webhook Endpoints
CREATE TABLE webhook_endpoints (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    url TEXT NOT NULL,
    signing_secret VARCHAR(128) NOT NULL,
    subscribed_events TEXT[] NOT NULL DEFAULT '{}',
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Audit Logs Table
CREATE TABLE audit_logs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
    actor_id UUID REFERENCES app_users(id) ON DELETE SET NULL,
    actor_email VARCHAR(255) NOT NULL,
    action audit_action NOT NULL,
    entity_type VARCHAR(64) NOT NULL,
    entity_id VARCHAR(64) NOT NULL,
    correlation_id UUID,
    client_ip INET,
    diff JSONB NOT NULL DEFAULT '{}',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================================
-- 8. AI AUTOMATION TABLES (SNAP-TO-ORDER & AUTONOMOUS FORECASTING)
-- ============================================================================

CREATE TABLE ai_po_parse_jobs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    actor_id UUID REFERENCES app_users(id) ON DELETE SET NULL,
    status VARCHAR(30) NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'PROCESSING', 'COMPLETED', 'FAILED')),
    file_url TEXT,
    raw_extracted_text TEXT,
    parsed_items JSONB NOT NULL DEFAULT '[]'::jsonb,
    matched_order_id UUID REFERENCES orders(id) ON DELETE SET NULL,
    confidence_score NUMERIC(4, 3) CHECK (confidence_score >= 0 AND confidence_score <= 1),
    error_message TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE ai_inventory_forecasts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    sku_id UUID NOT NULL REFERENCES skus(id) ON DELETE CASCADE,
    daily_burn_rate NUMERIC(12, 4) NOT NULL DEFAULT 0,
    runway_days NUMERIC(8, 2) NOT NULL DEFAULT 0,
    suggested_reorder_qty INT NOT NULL DEFAULT 0,
    risk_level VARCHAR(20) NOT NULL DEFAULT 'MEDIUM' CHECK (risk_level IN ('CRITICAL', 'HIGH', 'MEDIUM', 'LOW')),
    status VARCHAR(30) NOT NULL DEFAULT 'PENDING_REVIEW' CHECK (status IN ('PENDING_REVIEW', 'APPROVED', 'DISMISSED')),
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================================
-- 9. INDEXES FOR HIGH-CONCURRENCY PERFORMANCE
-- ============================================================================

CREATE INDEX idx_users_tenant_role ON app_users(tenant_id, role) WHERE deleted_at IS NULL;
CREATE INDEX idx_products_tenant_cat ON products(tenant_id, category_id, status) WHERE deleted_at IS NULL;
CREATE INDEX idx_skus_tenant_product ON skus(tenant_id, product_id) WHERE is_active = TRUE;
CREATE INDEX idx_channel_alloc_lookup ON inventory_channel_allocations(tenant_id, sku_id, channel);
CREATE INDEX idx_reservations_active ON inventory_reservations(sku_id, status, expires_at);
CREATE INDEX idx_orders_tenant_status ON orders(tenant_id, status, created_at DESC);
CREATE INDEX idx_audit_logs_lookup ON audit_logs(tenant_id, entity_type, entity_id, created_at DESC);
CREATE INDEX idx_ai_po_jobs_tenant ON ai_po_parse_jobs(tenant_id, status, created_at DESC);
CREATE INDEX idx_ai_forecast_tenant_sku ON ai_inventory_forecasts(tenant_id, sku_id, risk_level);

-- ============================================================================
-- 10. ROW-LEVEL SECURITY (RLS) POLICIES
-- ============================================================================

-- Helper Macro function for RLS
CREATE OR REPLACE FUNCTION current_tenant_scope() RETURNS UUID AS $$
BEGIN
    RETURN NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION is_superadmin_scope() RETURNS BOOLEAN AS $$
BEGIN
    RETURN COALESCE(current_setting('app.is_superadmin', true) = 'true', false);
END;
$$ LANGUAGE plpgsql STABLE;

-- Enable RLS on all tenant-specific tables
ALTER TABLE app_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE b2b_customer_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE products ENABLE ROW LEVEL SECURITY;
ALTER TABLE skus ENABLE ROW LEVEL SECURITY;
ALTER TABLE price_tiers ENABLE ROW LEVEL SECURITY;
ALTER TABLE tier_volume_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE b2b_buyer_tier_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE warehouses ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_physical_stock ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_channel_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_reservations ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_sync_conflicts ENABLE ROW LEVEL SECURITY;
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE order_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE b2b_bulk_order_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE webhook_endpoints ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE ai_po_parse_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE ai_inventory_forecasts ENABLE ROW LEVEL SECURITY;

-- Apply standard tenant isolation policy to all tables
DO $$
DECLARE
    tbl TEXT;
    tenant_tables TEXT[] := ARRAY[
        'app_users', 'b2b_customer_profiles', 'categories', 'products', 'skus',
        'price_tiers', 'tier_volume_rules', 'b2b_buyer_tier_assignments',
        'warehouses', 'inventory_physical_stock', 'inventory_channel_allocations',
        'inventory_reservations', 'inventory_sync_conflicts', 'orders',
        'order_items', 'b2b_bulk_order_batches', 'webhook_endpoints', 'audit_logs',
        'ai_po_parse_jobs', 'ai_inventory_forecasts'
    ];
BEGIN
    FOREACH tbl IN ARRAY tenant_tables LOOP
        EXECUTE format('
            CREATE POLICY tenant_isolation_policy ON %I
            AS RESTRICTIVE
            USING (is_superadmin_scope() OR tenant_id = current_tenant_scope())
            WITH CHECK (is_superadmin_scope() OR tenant_id = current_tenant_scope());
        ', tbl);
    END LOOP;
END;
$$;

-- ============================================================================
-- 10. ANALYTICAL REPORTING VIEWS
-- ============================================================================

-- Storefront Catalog View
CREATE OR REPLACE VIEW vw_storefront_catalog AS
SELECT 
    p.tenant_id,
    p.id AS product_id,
    p.title,
    p.slug AS product_slug,
    c.name AS category_name,
    s.id AS sku_id,
    s.sku_code,
    s.barcode,
    s.retail_price,
    ica.channel,
    GREATEST(ica.allocated_quantity - ica.safety_stock_buffer, 0) AS available_to_sell
FROM products p
JOIN categories c ON p.category_id = c.id
JOIN skus s ON p.id = s.product_id
JOIN inventory_channel_allocations ica ON s.id = ica.sku_id
WHERE p.status = 'PUBLISHED' 
  AND p.deleted_at IS NULL 
  AND s.is_active = TRUE;

-- Stock Health & Safety Stock Alerts View
CREATE OR REPLACE VIEW vw_stock_health_alerts AS
SELECT 
    ica.tenant_id,
    s.sku_code,
    ica.channel,
    ica.allocated_quantity,
    ica.safety_stock_buffer,
    (ica.allocated_quantity - ica.safety_stock_buffer) AS net_available,
    CASE 
        WHEN ica.allocated_quantity = 0 THEN 'DEPLETED'
        WHEN ica.allocated_quantity <= ica.safety_stock_buffer THEN 'CRITICAL'
        ELSE 'HEALTHY'
    END AS alert_status
FROM inventory_channel_allocations ica
JOIN skus s ON ica.sku_id = s.id;

-- Daily Sales Summary View
CREATE OR REPLACE VIEW vw_sales_summary_daily AS
SELECT 
    tenant_id,
    channel,
    DATE(created_at) AS sales_date,
    COUNT(id) AS total_orders,
    SUM(total_amount) AS gross_revenue,
    ROUND(AVG(total_amount), 2) AS average_order_value
FROM orders
WHERE status IN ('PAID', 'ALLOCATED', 'SHIPPED', 'DELIVERED')
GROUP BY tenant_id, channel, DATE(created_at);
