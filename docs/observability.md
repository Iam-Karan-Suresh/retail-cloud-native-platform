# Observability Guide

## Overview

The Retail Cloud Native Platform uses the **LGTM stack** (Loki, Grafana, Tempo, Mimir/Prometheus) with **OpenTelemetry** for full-stack observability across all 5 microservices.

## Architecture

```
┌─────────┐    ┌──────────┐    ┌───────────┐    ┌──────────┐    ┌──────────┐
│   UI    │───▶│ Catalog  │    │   Cart    │    │ Checkout │───▶│  Orders  │
│ (Java)  │    │  (Go)    │    │  (Java)   │    │ (Node)   │    │  (Java)  │
└────┬────┘    └─────┬────┘    └─────┬─────┘    └────┬─────┘    └─────┬────┘
     │               │               │               │               │
     │  ┌─────────── OTLP (HTTP :4318) ──────────────┘               │
     │  │                                                             │
     ▼  ▼                                                             ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                        OTel Collector                                   │
│  Receives: OTLP (gRPC :4317, HTTP :4318)                              │
│  Exports:  Traces → Tempo | Metrics → Prometheus | Logs → Loki       │
└───────────────┬────────────────┬───────────────────┬────────────────────┘
                │                │                   │
          ┌─────▼────┐    ┌─────▼──────┐     ┌──────▼────┐
          │  Tempo   │    │ Prometheus │     │   Loki    │
          │ (Traces) │    │ (Metrics)  │     │  (Logs)   │
          └─────┬────┘    └─────┬──────┘     └──────┬────┘
                │               │                   │
                └───────────────▼───────────────────┘
                          ┌──────────┐
                          │ Grafana  │
                          │ (:3000)  │
                          └──────────┘
```

## Instrumentation per Service

### UI (Java / Spring Boot WebFlux)
- **Auto**: `opentelemetry-spring-boot-starter` — instruments HTTP server/client, Spring WebFlux, database calls
- **Manual**: `@WithSpan` annotations on key controller methods
- **Propagation**: Automatic via Spring's `WebClient` (W3C TraceContext headers)

### Catalog (Go / Gin)
- **Auto**: `otelgin` middleware on all `/catalog` routes, GORM OTel plugin for MySQL queries
- **Manual**: Custom spans on `GetProducts`, `GetProduct` with business attributes (`tags`, `product.id`)
- **Propagation**: `propagation.TraceContext{}` + `propagation.Baggage{}` via `otel.SetTextMapPropagator`

### Cart (Java / Spring Boot)
- **Auto**: `opentelemetry-spring-boot-starter` — instruments HTTP server, DynamoDB SDK calls
- **Manual**: `@WithSpan` + `@SpanAttribute` on `CartsController` (get, delete, addItem)
- **Propagation**: Automatic via Spring's `RestTemplate`

### Checkout (Node.js / NestJS)
- **Auto**: `@opentelemetry/auto-instrumentations-node` — instruments HTTP server/client, Redis, Express
- **Manual**: Custom spans in `CheckoutService` (get, update, submit) with business attributes
- **Propagation**: Auto via `http` module instrumentation (injects `traceparent` on outbound calls to Orders API)

### Orders (Java / Spring Boot)
- **Auto**: `opentelemetry-spring-boot-starter` — instruments HTTP server, PostgreSQL/JDBC, RabbitMQ
- **Manual**: `@WithSpan` on `OrderController` (create, list) and `OrderService` (create, list)
- **Propagation**: Automatic via Spring's `RestTemplate`, RabbitMQ message headers

## End-to-End Trace Flow

```
User browser request
  └─▶ UI (span: GET /catalog)
       └─▶ Catalog API (span: catalog.get_products)
            └─▶ MySQL (span: gorm.query)

User adds to cart
  └─▶ UI (span: POST /carts/{id}/items)
       └─▶ Cart API (span: cart.add_item)
            └─▶ DynamoDB (span: dynamodb.PutItem)

User submits order
  └─▶ UI (span: POST /checkout/{id}/submit)
       └─▶ Checkout API (span: checkout.submit)
            └─▶ Redis GET (span: redis-GET)
            └─▶ Orders API (span: orders.create, propagated via traceparent)
                 └─▶ PostgreSQL (span: jdbc.query INSERT)
                 └─▶ RabbitMQ publish (span: rabbitmq.publish)
            └─▶ Redis DEL (span: redis-DEL)
```

## Environment Variables

All services share the following OTel environment variables (set in `compose.dev.yaml` via YAML anchor `x-otel-env`):

| Variable | Value | Purpose |
|----------|-------|---------|
| `OTEL_SERVICE_NAME` | Per-service (e.g., `checkout`) | Identifies the service in traces/metrics |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://otel-collector:4318` | OTLP HTTP endpoint |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `http/protobuf` | Wire protocol |
| `OTEL_PROPAGATORS` | `tracecontext,baggage` | W3C TraceContext propagation |
| `OTEL_TRACES_SAMPLER` | `always_on` | 100% sampling for dev |
| `OTEL_LOGS_EXPORTER` | `otlp` | Export logs via OTLP |
| `OTEL_METRICS_EXPORTER` | `otlp` | Export metrics via OTLP |
| `OTEL_SDK_DISABLED` | `false` | Enables OTel in Spring Boot apps |

## Grafana Dashboards

### Pre-provisioned Dashboards
- **Service Overview**: RED metrics (Rate, Error rate, Duration) per service
- **Trace Explorer**: Search and view distributed traces across all services
- **Log Explorer**: Correlated logs with trace IDs

### Correlation Features
- **Trace → Logs**: Click a trace in Tempo to see correlated logs in Loki
- **Trace → Metrics**: Service map visualization from Tempo span metrics
- **Logs → Trace**: Click trace IDs in Loki logs to jump to the full trace in Tempo
- **Metrics → Trace**: Exemplars in Prometheus link to specific traces

## Running Locally

```bash
# Start everything
DB_PASSWORD=testing docker compose -f compose/compose.dev.yaml up --build

# Access
# Grafana:    http://localhost:3000 (admin/admin)
# Prometheus: http://localhost:9090
# Tempo:      http://localhost:3200
# Loki:       http://localhost:3100
```
