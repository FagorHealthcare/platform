# Fagor Healthcare — Platform Meta-Repo

This repository is a **manifest and cross-service documentation layer** for
the Fagor Healthcare Medical Dispenser (MD) platform. **It is not a
monorepo.** No service code lives here.

The platform is composed of **14 independently versioned Git repositories**,
all hosted under [`https://github.com/FagorHealthcare/`](https://github.com/FagorHealthcare/)
(plus one personal fork). Each repo has its own build, its own CI/CD
pipeline, and its own release cadence. This repo only tracks:

- `CLAUDE.md` — instructions for AI agents working across the workspace
- `docs/` — system-wide architecture, deployment, operations, and incident
  documentation (start at [`docs/DOCS.md`](docs/DOCS.md))
- `bootstrap.sh` — clones every sibling repo into place on a fresh laptop
- `README.md` — this file
- `.gitignore` — defensively excludes every sub-repo directory

## Setting up a new laptop

```bash
# Pick a workspace directory
mkdir -p ~/Projects && cd ~/Projects

# Clone the meta-repo
git clone https://github.com/FagorHealthcare/platform.git FagorHealthcare
cd FagorHealthcare

# Clone every sibling repo as a peer directory inside this workspace
./bootstrap.sh
```

After `bootstrap.sh` finishes, the workspace layout is:

```
FagorHealthcare/
├── .git/                  ← this meta-repo
├── CLAUDE.md
├── README.md
├── bootstrap.sh
├── docs/
├── md-core/               ← independent repo
├── md-auth/               ← independent repo
├── md-resi-back/          ← independent repo
├── md-resi-front/         ← independent repo
├── md-pwa/                ← independent repo
├── md-backup/             ← independent repo
├── k8s/                   ← independent repo
├── do-functions/          ← independent repo
├── fhctl/                 ← independent repo
├── fmd-manual/            ← independent repo
├── pruebas-fmd-manual/    ← independent repo (personal fork)
├── postman-cinfa/         ← independent repo
├── sync-api-spec/         ← independent repo
└── md-resi-api-spec/      ← independent repo
```

## Working rules

- **Never modify service code through this repo.** Each sub-repo's working
  tree is `.gitignore`d here; changes belong in the sub-repo, committed
  and pushed to its own remote.
- **Per-service builds, deploys, and runbooks live in the sibling repos.**
  This repo only documents the platform as a whole.
- **Update workspace-level docs here.** Changes to architecture overviews,
  deployment runbooks, or incident records belong in `docs/` and ship as
  commits to this meta-repo.

## Documentation index

- [`CLAUDE.md`](CLAUDE.md) — workspace-level guidance for Claude Code
- [`docs/DOCS.md`](docs/DOCS.md) — index of all platform documentation
  - [`docs/SYSTEM.md`](docs/SYSTEM.md) — architecture overview
  - [`docs/SERVICES.md`](docs/SERVICES.md) — per-service reference
  - [`docs/INFRASTRUCTURE.md`](docs/INFRASTRUCTURE.md) — clusters, DNS, registries
  - [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md) — image tags, deploy/rollback
  - [`docs/OPERATIONS.md`](docs/OPERATIONS.md) — daily ops, certs, secrets
  - [`docs/INCIDENTS.md`](docs/INCIDENTS.md) — incident playbook and history
  - [`docs/fhctl-DESIGN.md`](docs/fhctl-DESIGN.md) — design sketch for `fhctl`
