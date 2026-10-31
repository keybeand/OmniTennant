# C2 — Container

> **Status:** Architecture Baseline · **Level:** C4 Level 2

The Container diagram zooms into the **OmniTenant Platform**, depicting the runtime executables, single-page web applications, backend services, caching layers, data stores, and communication protocols.

---

## 1. Container Architecture Diagram

```mermaid
flowchart TB
    admin(["Platform SuperAdmin / Tenant Owner / Warehouse Operator"])
    shopper(["B2B Buyer / B2C Shopper"])
    extWms[("External WMS / ERP")]

    subgraph platform["OmniTenant System Boundary"]
        direction TB

        subgraph frontendTier["Presentation Tier"]
            storefrontApp["<b>Customer Storefront</b><br/><i>[Container: React 19 + Vite]</i><br/>Public brand catalog, cart, 15m hold checkout,<br/>B2B bulk CSV order portal"]
            backofficeApp["<b>Admin Backoffice</b><br/><i>[Container: React 19 + Vite]</i><br/>Administrative console, catalog management,<br/>channel inventory hub, conflict reconciliation"]
        end

        subgraph apiTier["Application & Routing Tier"]
            apiGateway["<b>API Gateway & Reverse Proxy</b><br/><i>[Container: Nginx / YARP]</i><br/>Tenant domain resolution, SSL termination,<br/>rate-limiting, request routing"]
            backendApp["<b>OmniTenant Backend API</b><br/><i>[Container: ASP.NET Core 9.0 Web API]</i><br/>Multi-tenant middleware, CQRS application logic,<br/>two-phase reservation, audit & idempotency"]
            aiWorker["<b>Autonomous AI Worker</b><br/><i>[Container: .NET 9 BackgroundService]</i><br/>Async PO document parsing, 30-day sales velocity,<br/>predictive stockout & auto-replenishment"]
        end

        subgraph storageTier["Persistence & In-Memory Tier"]
            redisCache[("<b>Redis Cache & Lock</b><br/><i>[Container: Redis 7.2]</i><br/>Redlock distributed locks, 15-min reservation holds,<br/>idempotency cache, session lookup")]
            postgresDb[("<b>PostgreSQL Database</b><br/><i>[Container: PostgreSQL 16]</i><br/>Row-Level Security (RLS), multi-tenant catalog,<br/>AI jobs & forecasts, immutable audit trail")]
            blobStorage[("<b>Object Storage</b><br/><i>[Container: S3 / MinIO]</i><br/>Product gallery media, uploaded bulk CSV files,<br/>PO document scans, generated tax invoices")]
        end
    end

    llmService[("<b>Multimodal Vision & LLM Gateway</b><br/><i>[External: Gemini 1.5 / OpenAI]</i><br/>Document OCR, table extraction,<br/>fuzzy SKU name normalization")]

    shopper -- "HTTPS / JSON (Storefront Domain)" --> storefrontApp
    admin -- "HTTPS / JSON (/admin Console)" --> backofficeApp
    extWms -.->|"POST /api/v1/webhooks/inventory<br/>(HMAC SHA-256)"| apiGateway

    storefrontApp -- "REST / HTTPS / JSON" --> apiGateway
    backofficeApp -- "REST / HTTPS / JSON" --> apiGateway

    apiGateway -- "Forward with X-Tenant-ID" --> backendApp

    backendApp -- "Enqueue AI Jobs (RESP3)" --> redisCache
    aiWorker -- "Consume Jobs (Redis Streams)" --> redisCache
    aiWorker -- "Multimodal Vision Inference (HTTPS)" --> llmService
    aiWorker -- "Persist Predictions & Jobs (RLS SQL)" --> postgresDb

    backendApp -- "Distributed Locks & Holds (RESP3)" --> redisCache
    backendApp -- "SQL Queries (RLS Session Parameter)" --> postgresDb
    backendApp -- "S3 SDK / Pre-signed URLs" --> blobStorage

    classDef user fill:#4a5568,color:#fff,stroke:#2d3748
    classDef client fill:#3182ce,color:#fff,stroke:#2b6cb0
    classDef app fill:#1168bd,color:#fff,stroke:#0b4f9e
    classDef data fill:#1a365d,color:#fff,stroke:#0f2744

    class admin,shopper user
    class storefrontApp,backofficeApp client
    class apiGateway,backendApp,aiWorker app
    class redisCache,postgresDb,blobStorage,extWms,llmService data

    style platform fill:#f8fbff,stroke:#1168bd,stroke-dasharray:5 5
    style frontendTier fill:#ffffff,stroke:#cbd5e0,stroke-dasharray:3 3
    style apiTier fill:#ffffff,stroke:#cbd5e0,stroke-dasharray:3 3
    style storageTier fill:#ffffff,stroke:#cbd5e0,stroke-dasharray:3 3
```

---

## 2. Container Inventory & Technology Stack

| Container | Technology | Operational Responsibility |
|---|---|---|
| **Customer Storefront** | React 19, TypeScript, Vite | Single-page client for retail and wholesale buyers. Renders dynamic price tiers, live stock availability, 15-min countdown checkout, and CSV upload. |
| **Admin Backoffice** | React 19, TypeScript, Vite | Operational dashboard for Tenant Owners and Warehouse Operators. High-density data grids, SKU variant drawer, allocation matrix, and AI Copilot recommendations. |
| **API Gateway / Proxy** | Nginx / YARP (C#) | Ingress router. Extracts subdomain or custom CNAME (`{tenant-slug}.omnitenant.com`), injects `X-Tenant-ID`, terminates TLS, and enforces rate limits. |
| **OmniTenant Backend API** | ASP.NET Core 9.0 (.NET 9) | Core business engine implementing Clean Architecture. Validates tokens, coordinates Two-Phase Stock Reservation, evaluates volume pricing, and logs audits. |
| **Autonomous AI Worker** | .NET 9 BackgroundService | Asynchronous job consumer. Orchestrates PO document processing, calculates rolling stock consumption runways, and raises predictive replenishment alerts. |
| **Redis Cache & Lock** | Redis 7.2 | In-memory distributed lock manager (`Redlock`), ephemeral 15-minute reservation hold store, Redis Streams job queue, and 24-hour `Idempotency-Key` replay cache. |
| **PostgreSQL Database** | PostgreSQL 16 | Primary ACID relational database. Enforces tenant data segregation via native Row-Level Security (`app.current_tenant_id`), catalogs, orders, and AI forecast logs. |
| **Object Storage** | S3 / MinIO | Scalable object storage for product images, uploaded bulk CSV batches, uploaded PO document scans, and rendered PDF tax invoices. |
| **Multimodal Vision & LLM** | Google Gemini / OpenAI | External AI gateway providing document OCR, handwritten text extraction, and entity normalization for unstructured B2B purchase orders. |

---

## 3. Inter-Container Communication Protocols

- **Browser to API Gateway**: Secure HTTPS (TLS 1.3), JSON payloads, Bearer JWT authorization.
- **Backend API to Redis**: Redis Serialization Protocol (RESP3) via StackExchange.Redis connection multiplexer. Average lock acquisition latency < 2ms.
- **Backend API to PostgreSQL**: TCP/IP PostgreSQL wire protocol via Npgsql / Entity Framework Core. Session scoped via `SET LOCAL app.current_tenant_id = :tenantId`.
- **Backend API to Object Storage**: AWS S3 REST API via AWSSDK.S3 using pre-signed upload/download URLs.
- **AI Worker to Multimodal LLM**: Secure HTTPS REST API with structured JSON output schema enforcement. Latency bounded by streaming inference SLAs.
