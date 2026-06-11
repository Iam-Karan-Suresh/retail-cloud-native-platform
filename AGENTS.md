# Purpose
The Retail Cloud Native Platform is a microservices-based retail system designed to demonstrate cloud-native design, service orchestration, and observability (using the LGTM stack: Loki, Grafana, Tempo, Mimir/Prometheus, and OpenTelemetry).

# Ownership
- Team: Cloud Platform Engineers & Developers
- Primary Owner: Zoro
- Agent: Antigravity

# Local Contracts
- Every component must adhere to the microservices architecture patterns described in `SPOT-ARCHITECTURE-GUIDE.md` and `migration-guide.md`.
- Deployment and local orchestration configurations must be kept clean, validated, and consolidated in the `compose` directory.
- All Docker Compose configurations must validate successfully using `docker compose config`.
- All microservices must be instrumented with OpenTelemetry (auto + manual) exporting to the OTel Collector.
- W3C TraceContext propagation must be used across all inter-service HTTP calls.
- Argo Rollouts with automated canary analysis is the standard deployment strategy for Kubernetes.

# Work Guidance
- When modifying service configurations, ensure environment variables (e.g. database credentials, endpoints) are synchronized across dependent services.
- Keep ports and volume mounts mapped correctly.
- Use explicit healthchecks for stateful services (databases, cache) and configure dependent services with `depends_on` and `condition: service_healthy` where applicable.
- OTel environment variables are set via the `x-otel-env` YAML anchor in `compose.dev.yaml` — update the anchor when changing OTel settings globally.
- Java services use `otel.sdk.disabled: ${OTEL_SDK_DISABLED:true}` in `application.yml` — the compose env overrides this to `false`.

# Verification
- Run `docker compose -f compose/compose.dev.yaml config` to verify syntax and path resolution.

# Child DOX Index
- [compose/AGENTS.md](file:///home/zoro/Project/retail-cloud-native-platform/compose/AGENTS.md): Orchestrates local multi-container environments and observability infrastructure.
- [src/checkout/AGENTS.md](file:///home/zoro/Project/retail-cloud-native-platform/src/checkout/AGENTS.md): Core business logic and database connectivity for checkout flows.
- [docs/](file:///home/zoro/Project/retail-cloud-native-platform/docs/): Observability and Argo Rollouts documentation.
- [k8s/argo-rollouts/](file:///home/zoro/Project/retail-cloud-native-platform/k8s/argo-rollouts/): Argo Rollout manifests and AnalysisTemplates for progressive delivery.
