# C3 — Component (.NET Backend Architecture)

> **Status:** Architecture Baseline · **Level:** C4 Level 3

The Component diagram zooms into the **OmniTenant Backend API** container, revealing its modular design following **Clean Architecture** and **CQRS (Command Query Responsibility Segregation)**.

---

## 1. Component Architecture Diagram

```mermaid
flowchart TB
    apiGateway["API Gateway / Clients"]
    redisStore[("Redis 7.2")]
    postgresDb[("PostgreSQL 16")]
    s3Store[("S3 / MinIO")]

    subgraph backendContainer["OmniTenant Backend API [Container: ASP.NET Core 9.0]"]
        direction TB

        subgraph apiLayer["1. API / Presentation Layer"]
            direction LR
            tenantMw["Tenant Context Middleware<br/><i>[Middleware]</i><br/>Extracts tenant & injects into scope"]
            idempotencyMw["Idempotency Filter<br/><i>[Action Filter]</i><br/>Enforces Idempotency-Key validation"]
            authControllers["Auth & Tenant Controllers<br/><i>[Controller]</i>"]
            commerceControllers["Checkout & Order Controllers<br/><i>[Controller]</i>"]
            inventoryControllers["Inventory & Webhook Controllers<br/><i>[Controller]</i>"]
            catalogControllers["Catalog & Pricing Controllers<br/><i>[Controller]</i>"]
        end

        subgraph appLayer["2. Application Layer (CQRS with MediatR)"]
            direction TB
            subgraph commands["Commands (State Mutation)"]
                reserveCmd["ReserveStockCommandHandler<br/><i>[Command Handler]</i>"]
                confirmOrderCmd["ConfirmOrderCommandHandler<br/><i>[Command Handler]</i>"]
                webhookCmd["IngestWebhookCommandHandler<br/><i>[Command Handler]</i>"]
                bulkCsvCmd["ProcessBulkCsvCommandHandler<br/><i>[Command Handler]</i>"]
            end
            subgraph queries["Queries (Read Models)"]
                catalogQuery["GetFacetedCatalogQueryHandler<br/><i>[Query Handler]</i>"]
                pricingQuery["EvaluateDynamicPriceQueryHandler<br/><i>[Query Handler]</i>"]
                kpiQuery["GetDashboardKpisQueryHandler<br/><i>[Query Handler]</i>"]
            end
        end

        subgraph domainLayer["3. Domain Core (Enterprise Business Rules)"]
            direction LR
            reservationEngine["Two-Phase Reservation Service<br/><i>[Domain Service]</i><br/>Manages 15-min TTL hold lifecycle"]
            volumePricingEngine["Tiered Volume Pricing Engine<br/><i>[Domain Service]</i><br/>Evaluates quantity breaks & MOQs"]
            reconciliationService["Stock Reconciliation Service<br/><i>[Domain Service]</i><br/>Absorbs deficits into safety buffers"]
        end

        subgraph infraLayer["4. Infrastructure Tier"]
            direction LR
            redisLockService["Redis Distributed Lock Provider<br/><i>[Infrastructure Service]</i><br/>Redlock & ephemeral hold keys"]
            dbContext["ApplicationDbContext (EF Core)<br/><i>[Persistence Component]</i><br/>RLS interceptor & shadow tenant_id"]
            webhookValidator["HMAC Webhook Validator<br/><i>[Security Component]</i><br/>SHA-256 signature verifier"]
            invoiceGenerator["PDF Invoice Generator<br/><i>[Integration Component]</i><br/>QuestPDF rendering engine"]
        end
    end

    apiGateway --> tenantMw
    tenantMw --> idempotencyMw
    idempotencyMw --> authControllers & commerceControllers & inventoryControllers & catalogControllers

    commerceControllers --> reserveCmd & confirmOrderCmd
    inventoryControllers --> webhookCmd
    catalogControllers --> bulkCsvCmd & catalogQuery & pricingQuery

    reserveCmd --> reservationEngine
    confirmOrderCmd --> reservationEngine
    pricingQuery --> volumePricingEngine
    webhookCmd --> reconciliationService

    reservationEngine --> redisLockService
    reservationEngine --> dbContext
    confirmOrderCmd --> dbContext
    confirmOrderCmd --> invoiceGenerator
    webhookCmd --> webhookValidator

    redisLockService --> redisStore
    dbContext --> postgresDb
    invoiceGenerator --> s3Store

    classDef controller fill:#1168bd,color:#fff,stroke:#0b4f9e
    classDef handler fill:#2b6cb0,color:#fff,stroke:#1a4971
    classDef domain fill:#1a365d,color:#fff,stroke:#0f2744
    classDef infra fill:#3182ce,color:#fff,stroke:#2b6cb0
    classDef ext fill:#718096,color:#fff,stroke:#4a5568

    class authControllers,commerceControllers,inventoryControllers,catalogControllers controller
    class reserveCmd,confirmOrderCmd,webhookCmd,bulkCsvCmd,catalogQuery,pricingQuery,kpiQuery handler
    class reservationEngine,volumePricingEngine,reconciliationService domain
    class redisLockService,dbContext,webhookValidator,invoiceGenerator infra
    class apiGateway,redisStore,postgresDb,s3Store ext

    style backendContainer fill:#f8fbff,stroke:#1168bd,stroke-dasharray:5 5
```

---

## 2. Component Descriptions by Clean Architecture Layer

### 1. Presentation & API Layer
- **Tenant Context Middleware**: Extracts `tenant_id` from JWT claims or `X-Tenant-ID` header and initializes the scoped `ITenantContext` provider.
- **Idempotency Filter**: Intercepts mutating requests, queries Redis for duplicate in-flight or cached results, and prevents double execution.
- **REST Controllers**: Strongly typed ASP.NET Core controllers mapping HTTP verbs to MediatR Commands/Queries and formatting output as RFC 7807 `ProblemDetails`.

### 2. Application Layer (CQRS)
- **`ReserveStockCommandHandler`**: Executes Phase 1 of checkout. Coordinates distributed locking and persists 15-minute temporary holds.
- **`ConfirmOrderCommandHandler`**: Executes Phase 2 of checkout. Commits stock reservations to confirmed orders, updates B2B credit balances, and emits `OrderPlacedEvent`.
- **`IngestWebhookCommandHandler`**: Processes inbound WMS deltas, triggers auto-rebalancing against safety buffers, and routes discrepancies to the conflict queue.
- **`EvaluateDynamicPriceQueryHandler`**: Dynamically calculates the optimal unit price given a line-item quantity, SKU, and customer wholesale tier.

### 3. Domain Layer
- **Two-Phase Reservation Service**: Pure domain logic enforcing zero-overselling invariants:
  $$\text{AllocatedQuantity} - \text{SafetyBuffer} \ge \text{RequestedQuantity}$$
- **Tiered Volume Pricing Engine**: Evaluates nested price breaks, MOQ thresholds, and tier assignments.
- **Stock Reconciliation Service**: Determines whether external stock deficits can be absorbed by the safety buffer or require emergency channel allocation haircuts.

### 4. Infrastructure Layer
- **Redis Distributed Lock Provider**: Wraps Redlock algorithms using StackExchange.Redis with automatic lease renewal and deadlock prevention.
- **`ApplicationDbContext` (EF Core)**: Custom database context with a DbConnection interceptor that automatically executes `SET LOCAL app.current_tenant_id = :id` on every opened SQL connection.
- **HMAC Webhook Validator**: Computes cryptographic HMAC SHA-256 signatures over request byte streams to guarantee machine-to-machine authenticity.
- **PDF Invoice Generator**: Renders pixel-perfect, compliant B2B/B2C tax invoices using QuestPDF.
