# Fagor Healthcare — Documentation Index

This is the index of all system documentation for the Fagor Healthcare Medical Dispenser platform. Each linked document is self-contained but cross-references the others.

## Reading order

If you are new to the system, read in this order:

1. **[SYSTEM.md](SYSTEM.md)** — what the product is, how the pieces fit, the user journeys
2. **[SERVICES.md](SERVICES.md)** — per-service technical reference
3. **[INFRASTRUCTURE.md](INFRASTRUCTURE.md)** — clusters, registries, DNS, observability
4. **[DEPLOYMENT.md](DEPLOYMENT.md)** — how code becomes a running pod, rollback procedures
5. **[OPERATIONS.md](OPERATIONS.md)** — daily ops, certificates, secrets, troubleshooting
6. **[INCIDENTS.md](INCIDENTS.md)** — incident playbook and history
7. **[fhctl-DESIGN.md](fhctl-DESIGN.md)** — proposed CLI to make all of the above scriptable
8. **[observability-DESIGN.md](observability-DESIGN.md)** — design of the alerting/dashboarding layer on top of Loki (Loki Ruler + Alertmanager + Perses)
9. **[observability-mcp-DESIGN.md](observability-mcp-DESIGN.md)** — proposed MCP server exposing the observability stack to LLM clients (read-only, runs on platform droplet)
10. **[observability-AUTH.md](observability-AUTH.md)** — how operators authenticate to the platform (oauth2-proxy + GitHub today; migration plan to Microsoft/Google when Fagor confirms IdP)

## Cross-references

- [`../CLAUDE.md`](../CLAUDE.md) — entry point for Claude Code agents working in this workspace
- [`../k8s/CLAUDE.md`](../k8s/CLAUDE.md) — focused guidance for the Kubernetes manifests repo (cert-manager, Cinfa cert renewal, JWT keys)

## What is documented elsewhere

- **End-user documentation** (clinicians, residence staff, pharmacy operators) lives in the separate `fmd-manual/` repo and is published at https://fagorhealthcare.github.io/fmd-manual/.
- **API contracts** are in `sync-api-spec/` and `md-resi-api-spec/` (OpenAPI 3 YAML).
- **Per-repo READMEs** cover repo-specific build/test conventions; this doc set covers cross-cutting concerns only.
