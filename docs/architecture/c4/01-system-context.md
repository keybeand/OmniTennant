# C1 — System Context

> **Status:** Architecture Baseline · **Level:** C4 Level 1

The System Context diagram establishes the boundary of the **OmniTenant Platform**, identifying the human actors interacting with the system and the external third-party systems integrated via protocols.

---

## 1. System Context Diagram

```mermaid
flowchart TB
    superAdmin(["Platform SuperAdmin<br/><i>[Person]</i><br/>Manages global tenant provisioning,<br/>subscriptions, and platform audits"])
    tenantAdmin(["Tenant Owner<br/><i>[Person]</i><br/>Manages organization branding, staff RBAC,<br/>pricing tiers, and storefront config"])
    inventoryMgr(["Warehouse Operator<br/><i>[Person]</i><br/>Manages SKUs, safety buffers,<br/>and omnichannel stock allocations"])
    b2bBuyer(["B2B Buyer<br/><i>[Person]</i><br/>Orders via volume price tiers, corporate credit lines,<br/>and bulk CSV uploads"])
    b2cCustomer(["B2C Shopper<br/><i>[Person]</i><br/>Browses public storefront, reserves stock,<br/>and checkouts concurrently"])

    subgraph boundary["OmniTenant System Boundary"]
        omniSystem["<b>OmniTenant Platform</b><br/><i>[Software System]</i><br/>Cloud-native B2B/B2C multi-tenant commerce<br/>and real-time omnichannel inventory synchronization"]
    end

    subgraph external["External Third-Party Systems"]
        direction TB
        paymentGateway["Payment Gateway<br/><i>[External System: Stripe / VNPay]</i><br/>Processes card authorizations & payouts"]
        externalWMS["External WMS / ERP<br/><i>[External System: SAP / KiotViet]</i><br/>Sends physical inventory deltas via HMAC webhooks"]
        emailService["Notification Service<br/><i>[External System: SendGrid / SES]</i><br/>Dispatches tenant invitations & order receipts"]
    end

    superAdmin -- "Provisions tenants & audits logs" --> omniSystem
    tenantAdmin -- "Configures storefront & price tiers" --> omniSystem
    inventoryMgr -- "Allocates channel inventory & balances stock" --> omniSystem
    b2bBuyer -- "Submits bulk purchase orders & tracks POs" --> omniSystem
    b2cCustomer -- "Buys products & checks out with 15m hold" --> omniSystem

    omniSystem -- "Settles customer payments" --> paymentGateway
    externalWMS -.->|"Pushes inventory deltas via HMAC Webhook"| omniSystem
    omniSystem -- "Sends transactional emails" --> emailService

    classDef person fill:#4a5568,color:#fff,stroke:#2d3748
    classDef system fill:#1168bd,color:#fff,stroke:#0b4f9e
    classDef externalStyle fill:#718096,color:#fff,stroke:#4a5568

    class superAdmin,tenantAdmin,inventoryMgr,b2bBuyer,b2cCustomer person
    class omniSystem system
    class paymentGateway,externalWMS,emailService externalStyle

    style boundary fill:#f7fafc,stroke:#1168bd,stroke-dasharray:5 5
    style external fill:#edf2f7,stroke:#a0aec0,stroke-dasharray:5 5
```

---

## 2. External Actors & Responsibilities

| Actor | Role Code | Responsibility within OmniTenant |
|---|---|---|
| **Platform SuperAdmin** | `SUPERADMIN` | Platform root owner. Provisions new isolated tenant organizations, sets resource limits, and reviews global audit logs. |
| **Tenant Owner** | `TENANT_OWNER` | Merchant brand administrator. Configures custom domains, price tiers, corporate credit limits, and staff RBAC. |
| **Warehouse Operator** | `WAREHOUSE_OPERATOR` | Fulfillment specialist. Tracks physical SKU stock, adjusts safety buffers, allocates quotas, and reconciles count divergence. |
| **B2B Buyer** | `B2B_BUYER` | Corporate wholesale client. Orders bulk merchandise at contract volume discount prices using credit terms or POs. |
| **B2C Shopper** | `B2C_SHOPPER` | Retail customer. Purchases products on brand storefronts with high-concurrency stock reservation guarantees. |

---

## 3. External System Interfaces

| External System | Integration Protocol | Interaction Purpose |
|---|---|---|
| **Payment Gateway** (Stripe / VNPay) | HTTPS REST API | Processes 3D-Secure credit card token authorizations during Phase 2 of checkout. |
| **External WMS / ERP** (KiotViet / SAP) | Inbound HMAC Webhook | Delivers machine-to-machine physical stock deltas; verified by HMAC SHA-256 and `Idempotency-Key`. |
| **Notification Service** (SendGrid) | SMTP / REST API | Dispatches tenant invitation links, password resets, low-stock threshold warnings, and PDF invoice receipts. |
