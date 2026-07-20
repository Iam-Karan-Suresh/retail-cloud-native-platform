# Purpose
The checkout microservice provides an API to manage customers' checkout sessions and coordinate with the orders service.

# Ownership
- Owner: Zoro
- Agent: Antigravity

# Local Contracts
- Connects to a Redis database (`checkout-redis`) for session persistence.
- Communicates with the orders service via HTTP (`http://orders:8080`).

# Work Guidance
- Use the Node.js/NestJS framework.
- Local compose configuration is defined in `docker-compose.yaml`.
- Ensure standard OpenTelemetry instrumentation is maintained in `src/instrumentation.ts`.

# Verification
- Run local lint and tests before committing changes.
- Verify container execution using the compose configurations.
