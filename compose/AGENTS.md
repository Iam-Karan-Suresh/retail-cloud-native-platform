# Purpose
Manage docker-compose orchestration for local development and the LGTM observability stack.

# Ownership
- Owner: Zoro
- Agent: Antigravity

# Local Contracts
- All local development services must be defined or combined within `compose.dev.yaml` using `extends`.
- Custom bridge networks `app` and `observability` segregate application and monitoring containers.
- OTel environment variables are centralized via the `x-otel-env` YAML anchor — do not duplicate them per service.
- Grafana datasources must be configured with full cross-correlation (Tempo↔Loki, Tempo↔Prometheus, Prometheus→Tempo exemplars).

# Work Guidance
- Build contexts are resolved relative to the extended source file (e.g. `../src/<service>`).
- Relative watch paths in `develop.watch` must point to folders relative to the compose file.
- Avoid hardcoded secrets; use `.env` file or environment variables.
- When adding a new service, set `OTEL_SERVICE_NAME` and include `<<: *otel-env` in its environment block.
- Prometheus scrape configs must be updated in `prometheus-config.yaml` when adding new services.

# Verification
- Validate config structure using:
  `docker compose -f compose/compose.dev.yaml config`
