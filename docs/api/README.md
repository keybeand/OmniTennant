# OmniTenant API Documentation

> Design status: TARGET V1
>
> Implementation status: CONTRACT DEFINED (OpenAPI 3.0.3)

## Overview

This is the official API specification for the **OmniTenant Platform**. The single source of truth for all HTTP endpoints, request and response models, authentication flows, error taxonomy, and concurrency controls is defined in [openapi.yaml](openapi.yaml).

All operations map directly to the 18 Use Cases (`UC01 – UC18`) and the 27 frontend interfaces (`SCR-01` $\rightarrow$ `SCR-105`) codified in [03-use-cases.md](../03-use-cases.md) and [04-information-architecture.md](../04-information-architecture.md).

---

## 1. API Scopes & Resource Domains

1. **Authentication & Tenant Governance (`/auth`, `/tenants`)**: Multi-tenant sign-in, MFA verification, tenant context switching, and automated SaaS tenant provisioning (`UC01, UC02, UC05`).
2. **Catalog & SKU Variants (`/products`, `/skus`, `/storefront/catalog`)**: Multi-attribute product masters, variant units, barcodes, and faceted search (`UC10, UC15`).
3. **Wholesale Pricing & Tiered Volume Rules (`/pricing`)**: B2B price lists, MOQ volume break discount matrix, dynamic buyer tier resolution (`UC09`).
4. **Omnichannel Inventory Allocation (`/inventory`)**: Channel split (Online B2C vs. Wholesale B2B vs. Retail), safety stock buffers, conflict reconciliation queue, and WMS webhook ingestion (`UC11, UC12, UC13, UC14`).
5. **High-Concurrency Checkout & Orders (`/checkout`, `/orders`)**: Two-phase stock reservation (15-min TTL hold), idempotent payment settlement, order tracking, and PDF tax invoice generation (`UC16, UC17`).
6. **B2B Bulk Order Upload (`/b2b/bulk-orders`)**: Asynchronous/synchronous CSV & Excel file parsing, line-by-line stock & MOQ validation, and batch wholesale creation (`UC18`).
7. **Staff & RBAC Administration (`/users`)**: Staff directory, member invitation, role permission policies (`UC06`).
8. **Observability & Analytics (`/analytics`, `/audit-logs`)**: Real-time sales KPIs, stock health alerts, and immutable compliance audit trails (`UC04, UC08`).

---

## 2. Base URLs

- **Local Development**: `http://localhost:5000/api/v1`
- **Docker Compose Environment**: `http://api.omnitenant.local/api/v1`
- **Multi-Tenant Subdomain Ingress**: `https://{tenant-slug}.omnitenant.com/api/v1`

---

## 3. Authentication & Tenant Context Binding

### JWT Bearer Authentication
All protected endpoints require a short-lived JSON Web Token (15-minute expiration) passed in the `Authorization` header:

```http
Authorization: Bearer <JWT_ACCESS_TOKEN>
```

The JWT payload is stateless and self-contained, encapsulating `user_id`, `tenant_id`, and `role` claims.

### Tenant Resolution Header (`X-Tenant-ID`)
For API clients accessing via root endpoints or mobile clients, the tenant context can be supplied explicitly:

```http
X-Tenant-ID: c0a80123-0000-0000-0000-000000000001
```

If both a custom domain (or subdomain) and `X-Tenant-ID` are present, the token's cryptographically signed `tenant_id` claim takes highest priority to prevent tenant spoofing.

---

## 4. Concurrency, Idempotency & Webhook Security

### Idempotency Enforcement (`Idempotency-Key`)
To prevent accidental duplicate payments or repeated inventory decrements caused by network timeouts or user retry clicks, all mutating commerce endpoints (`POST /checkout/confirm` and `POST /webhooks/inventory`) **mandate** an `Idempotency-Key` header with a unique UUID v4:

```http
Idempotency-Key: e4b281f6-7b2a-41d3-9bc0-88029a0e671b
```

- When a request is received with an `Idempotency-Key`, the system checks Redis.
- If the request is currently in-flight, subsequent requests return `409 Conflict` with `IDEMPOTENCY_IN_PROGRESS`.
- If the request has already succeeded within the 24-hour cache window, the previously committed response is returned immediately without re-executing inventory decrements or charges.

### Webhook HMAC SHA-256 Signatures
Inbound webhooks from external Warehouse Management Systems (WMS) must include an HMAC SHA-256 signature calculated over the request body using the tenant's webhook signing secret:

```http
X-OmniTenant-Signature: 7d2b4510... (64-character hex string)
X-OmniTenant-Timestamp: 1730295600
```

Requests with timestamps older than ±5 minutes are rejected to prevent replay attacks.

---

## 5. Content Types & Data Conventions

- **Request & Response Bodies**: `application/json`
- **Standard Error Responses**: `application/problem+json` (RFC 7807)
- **Bulk File Uploads**: `multipart/form-data` (CSV / XLSX, max 5 MB and 2,000 line items)
- **Official Invoices**: `application/pdf`
- **Dates & Times**: ISO 8601 UTC (`YYYY-MM-DDTHH:mm:ssZ`)
- **Monetary Amounts**: Fixed-point numeric with 2 decimal places in tenant base currency (e.g. `"150.00"`).

---

## 6. Standard Pagination

Endpoints returning lists accept query parameters:
- `page`: 1-based index (Default: `1`).
- `pageSize`: Items per page (Default: `20`, Maximum: `100`).

Paginated response wrapper format:
```json
{
  "items": [...],
  "meta": {
    "page": 1,
    "pageSize": 20,
    "totalItems": 142,
    "totalPages": 8
  }
}
```

---

## 7. Standard Error Handling (RFC 7807 ProblemDetails)

All errors return `application/problem+json`:

```json
{
  "type": "https://api.omnitenant.com/errors/insufficient-stock",
  "title": "Insufficient Stock",
  "status": 409,
  "detail": "Requested quantity exceeds available-to-sell channel inventory.",
  "instance": "/api/v1/checkout/reserve",
  "errorCode": "INSUFFICIENT_STOCK",
  "traceId": "00-4bf92f3577b34da6a3ce929d0e0e4736-00",
  "invalidSkus": [
    {
      "skuCode": "SKU-IPHONE15-BLK",
      "requested": 5,
      "available": 2
    }
  ]
}
```

### Primary `errorCode` Taxonomy

| HTTP Status | `errorCode` | Description |
|:---:|---|---|
| **400** | `BAD_REQUEST` | Malformed JSON syntax or missing required parameters. |
| **401** | `AUTH_UNAUTHORIZED` | Bearer token missing, expired, or invalid. |
| **401** | `WEBHOOK_INVALID_SIGNATURE` | HMAC SHA-256 signature verification failed. |
| **403** | `ACCESS_DENIED` | Role lacks permission for this resource or cross-tenant violation. |
| **404** | `RESOURCE_NOT_FOUND` | Entity does not exist within the authenticated tenant scope. |
| **409** | `INSUFFICIENT_STOCK` | Stock allocation depleted during reservation attempt. |
| **409** | `IDEMPOTENCY_CONFLICT` | Same idempotency key is currently processing. |
| **409** | `SLUG_ALREADY_EXISTS` | Tenant slug or SKU code is already taken. |
| **422** | `VALIDATION_FAILED` | Semantic validation failed (e.g. MOQ not met, negative price). |
| **422** | `QUOTA_EXCEEDED` | Tenant exceeded subscription plan limit (e.g. max SKUs reached). |
| **500** | `INTERNAL_SERVER_ERROR` | Unhandled platform error; check server logs via `traceId`. |

---

## 8. Sample cURL Workflows

### 8.1 Universal Login & Tenant Switch
```bash
# Step 1: Login
curl -X POST http://localhost:5000/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{
    "email": "owner@brand.local",
    "password": "SecurePassword123!"
  }'

# Step 2: Switch to Tenant Context (if user belongs to multiple organizations)
curl -X POST http://localhost:5000/api/v1/auth/switch-tenant \
  -H "Authorization: Bearer <INITIAL_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{
    "tenantId": "c0a80123-0000-0000-0000-000000000001"
  }'
```

### 8.2 Browse Catalog with Faceted Filters
```bash
curl -X GET "http://localhost:5000/api/v1/storefront/catalog?category=electronics&inStockOnly=true&page=1&pageSize=20" \
  -H "X-Tenant-ID: c0a80123-0000-0000-0000-000000000001" \
  -H "Accept: application/json"
```

### 8.3 Two-Phase Stock Reservation (Phase 1: Reserve 15-min Hold)
```bash
curl -X POST http://localhost:5000/api/v1/checkout/reserve \
  -H "Content-Type: application/json" \
  -H "X-Tenant-ID: c0a80123-0000-0000-0000-000000000001" \
  -d '{
    "channel": "ONLINE_B2C",
    "cartId": "a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d",
    "items": [
      { "skuCode": "SKU-TSHIRT-BLK-L", "quantity": 2 }
    ]
  }'
```

### 8.4 Idempotent Order Checkout (Phase 2: Confirm Order)
```bash
curl -X POST http://localhost:5000/api/v1/checkout/confirm \
  -H "Content-Type: application/json" \
  -H "X-Tenant-ID: c0a80123-0000-0000-0000-000000000001" \
  -H "Idempotency-Key: e4b281f6-7b2a-41d3-9bc0-88029a0e671b" \
  -d '{
    "reservationId": "f7e6d5c4-b3a2-1098-7654-3210fedcba98",
    "paymentMethod": "CREDIT_CARD",
    "paymentToken": "tok_visa_4242",
    "shippingAddress": {
      "recipientName": "Nguyen Van A",
      "addressLine1": "123 Le Loi, District 1",
      "city": "Ho Chi Minh City",
      "country": "VN"
    }
  }'
```

### 8.5 Ingest External WMS Inventory Webhook
```bash
curl -X POST http://localhost:5000/api/v1/webhooks/inventory \
  -H "Content-Type: application/json" \
  -H "X-Tenant-ID: c0a80123-0000-0000-0000-000000000001" \
  -H "Idempotency-Key: 99887766-5544-3322-1100-aabbccddeeff" \
  -H "X-OmniTenant-Signature: 5d41402abc4b2a76b9719d911017c592" \
  -H "X-OmniTenant-Timestamp: 1730295600" \
  -d '{
    "warehouseCode": "WH-NORTH-01",
    "batchId": "BATCH-2026-10-30-001",
    "deltas": [
      { "skuCode": "SKU-TSHIRT-BLK-L", "physicalDelta": 100 }
    ]
  }'
```

### 8.6 B2B Bulk Order Upload (CSV Validation)
```bash
curl -X POST http://localhost:5000/api/v1/b2b/bulk-orders/validate \
  -H "Authorization: Bearer <B2B_BUYER_TOKEN>" \
  -F "file=@wholesale_order_november.csv"
```

### 8.7 AI-Driven B2B Purchase Order Parsing (Snap-to-Order)
```bash
curl -X POST http://localhost:5000/api/v1/orders/ai-parse-po \
  -H "Authorization: Bearer <B2B_BUYER_TOKEN>" \
  -F "file=@handwritten_purchase_order.jpg"
```

### 8.8 Fetch AI Stockout Forecasting & Recommendations
```bash
curl -X GET "http://localhost:5000/api/v1/inventory/ai-forecast?riskLevel=CRITICAL" \
  -H "Authorization: Bearer <TENANT_STAFF_TOKEN>"
```

### 8.9 Activate Autonomous Dead-Stock Markdown Campaign
```bash
curl -X POST http://localhost:5000/api/v1/pricing/ai-markdown-proposals/c0a80123-0000-0000-0000-000000000042/activate \
  -H "Authorization: Bearer <TENANT_STAFF_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{ "durationHours": 48 }'
```

---

## 9. Contract Verification & Tooling

To view or validate `openapi.yaml` locally:

1. **Swagger Editor**: Open [https://editor.swagger.io](https://editor.swagger.io) and paste `openapi.yaml`.
2. **Redocly CLI Linting**:
   ```bash
   npx @redocly/cli lint docs/api/openapi.yaml
   ```
3. **Redocly Documentation Server**:
   ```bash
   npx @redocly/cli preview-docs docs/api/openapi.yaml
   ```

---

**Related:** [OpenAPI 3.0 Contract](openapi.yaml) · [Use Cases](03-use-cases.md) · [Acceptance Criteria](06-acceptance-criteria.md) · [Database Schema](../DATABASE.md)
