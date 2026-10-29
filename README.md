
# OmniTenant

OmniTenant is a cloud-native B2B/B2C multi-tenant commerce and inventory synchronization platform. It enables brand owners and distributors to manage isolated storefronts, track omnichannel inventory allocations in real time, execute bulk wholesale orders, and handle high-concurrency checkout with strong data consistency and row-level tenant isolation.

## 1. Requirements — INVEST, Use Cases, and Acceptance Criteria

Requirements define the operational scope, actor responsibilities, transactional integrity rules, and observable acceptance criteria for OmniTenant. Backlog items are structured using the INVEST model and validated against high-concurrency business flows.

### 1.1 Product Mind Map

![OmniTenant mind map](docs/mindmap.png)

### 1.2 INVEST Requirements

The V1 scope includes 18 core user stories spanning multi-tenant authentication, dynamic catalog management, distributed inventory tracking, B2B wholesale orders, high-concurrency B2C checkout, webhook synchronization, and administrative audit trails. Each user story is evaluated and refined against the INVEST criteria before implementation.

| Criterion | Meaning in OmniTenant |
| :--- | :--- |
| **Independent** | Feature stories, such as catalog browsing and order checkout, are decoupled through well-defined domain events and boundaries. |
| **Negotiable** | Cart storage engines and inventory reservation backends, such as Redis or database locks, can vary as long as consistency contracts hold. |
| **Valuable** | Each capability delivers tangible business outcomes, including multi-tenant isolation, inventory overselling prevention, and B2B volume pricing. |
| **Estimable** | Data access boundaries, idempotency keys, isolation requirements, and rollback behaviors are documented. |
| **Small** | Complex workflows, such as two-phase checkout, are decomposed into discrete API, locking, persistence, and event-dispatch tasks. |
| **Testable** | Every story maps to measurable acceptance criteria covering race-condition behavior, RBAC constraints, and tenant boundary enforcement. |

#### V1 User Story Overview

```text
US01–US02    Platform & Tenant Authentication (JWT, Tenant Context)
US03         Tenant Onboarding & Domain Provisioning
US04–US06    Multi-Tenant Catalog Management (SKUs, Variants, Attributes)
US07–US09    Real-Time Inventory Allocation & Channel Reservations
US10–US12    B2B Wholesale Ordering & Tiered Volume Pricing
US13–US14    B2C High-Concurrency Checkout & Idempotent Payment
US15         Omnichannel Webhook Ingestion & External Inventory Sync
US16         Audit Logging & Distributed Traceability
US17         Tenant User Management & Role-Based Permissions
US18         Merchant Storefront Configuration & Webhook Endpoints
```

All V1 stories guarantee strong tenant data segregation at the persistence tier through `tenant_id` query scoping, atomic inventory decrement using pessimistic or distributed Redis locks, and idempotency key enforcement on all checkout requests.

Detailed specifications are maintained in the **INVEST Requirements Catalog**.

### 1.3 Use Cases

The following diagram illustrates the primary actors, their responsibilities, and the use cases supported by OmniTenant.

```mermaid
flowchart TB
    subgraph roles["Actors"]
        direction LR
        superAdmin(["Platform SuperAdmin"])
        tenantAdmin(["Tenant Owner"])
        inventoryMgr(["Warehouse Operator"])
        b2bBuyer(["B2B Buyer"])
        b2cCustomer(["B2C Shopper"])
    end

    subgraph system["OmniTenant — System Boundary"]
        direction LR

        superCases["<b>Platform SuperAdmin</b><br/><br/>UC01 Global Login<br/>UC02 Provision Tenant<br/>UC03 Manage Global Subscriptions<br/>UC04 Audit Platform Logs"]

        tenantCases["<b>Tenant Owner</b><br/><br/>UC05 Tenant Login & Switch<br/>UC06 Manage Tenant Users & RBAC<br/>UC07 Configure Storefront & Webhooks<br/>UC08 View Aggregated Analytics<br/>UC09 Manage Price Tiers"]

        inventoryCases["<b>Warehouse Operator</b><br/><br/>UC10 Manage Catalog & SKUs<br/>UC11 Adjust Safety Stock<br/>UC12 Allocate Channel Inventory<br/>UC13 Ingest Inventory Webhook<br/>UC14 Resolve Sync Conflicts"]

        buyerCases["<b>B2B Buyer & B2C Shopper</b><br/><br/>UC15 Browse Catalog & Prices<br/>UC16 Reserve Stock & Checkout<br/>UC17 Track Order & Invoices<br/>UC18 Bulk Order Upload (B2B)"]
    end

    superAdmin --> superCases
    tenantAdmin --> tenantCases
    inventoryMgr --> inventoryCases
    b2bBuyer --> buyerCases
    b2cCustomer --> buyerCases

    classDef actor fill:#4a5568,color:#fff,stroke:#2d3748
    classDef platform fill:#1a365d,color:#fff,stroke:#0f2744
    classDef tenant fill:#1168bd,color:#fff,stroke:#0b4f9e
    classDef ops fill:#2b6cb0,color:#fff,stroke:#1a4971
    classDef client fill:#3182ce,color:#fff,stroke:#2b6cb0

    class superAdmin,tenantAdmin,inventoryMgr,b2bBuyer,b2cCustomer actor
    class superCases platform
    class tenantCases tenant
    class inventoryCases ops
    class buyerCases client

    style roles fill:#ffffff,stroke:#cbd5e0,stroke-dasharray:5 5
    style system fill:#f7fafc,stroke:#2b6cb0,stroke-dasharray:5 5
```

Detailed preconditions, happy paths, edge cases, and postconditions are documented in the **Use Case Specifications**.

### 1.4 Roles and Permissions

| Capability | Platform SuperAdmin | Tenant Owner | Warehouse Operator | B2B Buyer | B2C Shopper |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Tenant Provisioning** | Yes | No | No | No | No |
| **Manage Tenant Settings & API Keys** | Global view | Yes (Own tenant) | No | No | No |
| **Manage Catalog (Products, SKUs)** | Global view | Yes (Own tenant) | Yes (Own tenant) | No | No |
| **Allocate & Adjust Stock** | No | Yes (Own tenant) | Yes (Own tenant) | No | No |
| **Configure Tiered Pricing** | No | Yes (Own tenant) | No | No | No |
| **Place Orders / Checkout** | No | No | No | Yes (Wholesale tier) | Yes (Retail tier) |
| **Process External Sync Webhooks** | System level | Yes | Yes | No | No |
| **View Audit Logs** | Global audit | Tenant audit | No | No | No |

Tenant isolation is verified at every API boundary. Every authenticated principal context carries a cryptographically validated `TenantId`, which is injected directly into database queries and cache keys to prevent cross-tenant data leakage.

## 2. Information Architecture, Screen Hierarchy, and UI/UX

The Information Architecture maps out the structural layout of both the Backoffice workspace and the Public Storefront. Screen composition follows an explicit block-level anatomy pattern, defining headers, controls, data views, and action triggers for each operational interface.

### 2.1 Information Architecture

The following diagram illustrates the hierarchy of the OmniTenant platform, including the Tenant Admin Backoffice and the Customer Storefront.

```mermaid
flowchart TD
    PlatformRoot["OmniTenant System Shell"]

    %% Backoffice
    BackofficeApp["Tenant Admin Backoffice (/admin)"]

    DashboardPage["<b>Dashboard Page (/admin/dashboard)</b><br/><br/>---<br/>• Header & Global Tenant Switcher<br/>• Real-Time Sales & Inventory KPI Cards<br/>• Channel Allocation Status Breakdown<br/>• Recent Sync Conflicts & Audit Widget<br/>• Quick Action Bar (Add SKU, Rebalance Stock)"]

    CatalogPage["<b>Catalog Management (/admin/catalog)</b><br/><br/>---<br/>• Page Title & Bulk Action Controls<br/>• Multi-Attribute Filter (Category, Status, Channel)<br/>• SKU & Variant Inventory Data Grid<br/>• Inline Price Tier Configurator<br/>• Batch Import / Export Toolbar"]

    InventoryPage["<b>Inventory Allocation Hub (/admin/inventory)</b><br/><br/>---<br/>• Channel Header (Online, Wholesale, Retail)<br/>• Safety Stock Threshold Monitor<br/>• Warehouse Reservation Splitter Table<br/>• Manual Stock Override Modal<br/>• Webhook Sync Log Viewer"]

    OrdersPage["<b>Order Fulfillment (/admin/orders)</b><br/><br/>---<br/>• Order Status Tabs (Pending, Reserved, Fulfilled)<br/>• Search & Date Range Picker<br/>• Master-Detail Order Grid<br/>• B2B Credit Limit & Approval Drawer<br/>• Invoice Generation & Export CTA"]

    %% Storefront
    StorefrontApp["Customer Storefront (/{tenant-slug})"]

    CatalogBrowse["<b>Storefront Catalog (/products)</b><br/><br/>---<br/>• Brand Navigation Bar & Search<br/>• Category Hierarchy & Faceted Filters<br/>• Dynamic Price Grid (Tiered/Retail)<br/>• Stock Availability Indicator<br/>• Quick Add-to-Cart Trigger"]

    CheckoutFlow["<b>Checkout & Allocation (/checkout)</b><br/><br/>---<br/>• Multi-Step Breadcrumb Header<br/>• Customer Info & Tax Validation Form<br/>• Real-Time Stock Reservation Notice<br/>• Payment Gateway Integration Block<br/>• Order Review & Confirm CTA"]

    %% Hierarchical relationships
    PlatformRoot --> BackofficeApp
    PlatformRoot --> StorefrontApp

    BackofficeApp --> DashboardPage
    BackofficeApp --> CatalogPage
    BackofficeApp --> InventoryPage
    BackofficeApp --> OrdersPage

    StorefrontApp --> CatalogBrowse
    StorefrontApp --> CheckoutFlow

    classDef container fill:#ffffff,stroke:#1168bd,stroke-width:2px,color:#000,text-align:left
    class DashboardPage,CatalogPage,InventoryPage,OrdersPage,CatalogBrowse,CheckoutFlow container
```
