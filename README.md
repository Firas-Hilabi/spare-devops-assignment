# Notifications API — DevOps Assignment

[![CI/CD](https://github.com/Firas-Hilabi/spare-devops-assignment/actions/workflows/ci.yml/badge.svg)](https://github.com/Firas-Hilabi/spare-devops-assignment/actions/workflows/ci.yml)

A small Node.js + Express + PostgreSQL REST API, made **runnable, repeatable, and
deployable** with Docker, Docker Compose, GitHub Actions, and a Bash operations script.

> The application code under `src/` is the provided starter and is **unchanged** — all
> work here is infrastructure, automation, and tooling around it.

---

## Contents

- [Quick start](#quick-start)
- [Architecture](#architecture)
- [API endpoints](#api-endpoints)
- [Operations script](#operations-script)
- [CI/CD](#cicd)
- [Cloud deployment (Render)](#cloud-deployment-render)
- [Design decisions & trade-offs](#design-decisions--trade-offs)
- [Assumptions](#assumptions)
- [Project structure](#project-structure)

---

## Quick start

**Prerequisites:** Docker Desktop (or Docker Engine) with Compose v2.

```bash
cp .env.example .env          # seed local config (ops.sh does this for you too)
./scripts/ops.sh up           # build + start API and Postgres, wait until healthy
```

Then:

```bash
curl http://localhost:8080/health
curl http://localhost:8080/users
```

Or with `make`: `make up`, `make smoke`, `make down`.

Tear down with `./scripts/ops.sh down` (the database volume is preserved).

---

## Architecture

```
            host:8080
                │
        ┌───────▼────────┐        ┌──────────────────┐
        │   api (Node)   │  appnet │   db (Postgres)  │
        │  Express :8080 ├────────►│      :5432       │
        │  non-root,tini │ DB_HOST │  volume: pgdata  │
        └───────┬────────┘  = db   └──────────────────┘
                │
           GET /health  ──►  SELECT 1  (DB-backed liveness)
```

- The two services share a private bridge network (`appnet`) and resolve each other by
  service name — the API connects to Postgres at `DB_HOST=db`.
- Postgres data persists in a named volume (`pgdata`) across restarts.
- **`/health` runs `SELECT 1`**, so a `200` means the app *and* its database are up. This
  single signal drives the Compose healthcheck, the operational script, and CI.
- The app **creates its own tables** on startup (`CREATE TABLE IF NOT EXISTS` in
  `src/db.js`), so no separate migration/seed step is needed — but it *does* require the
  database to be reachable at boot, which is why startup ordering matters (below).

---

## API endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET  | `/health` | Health check (includes DB connectivity) |
| GET  | `/users` | List all users |
| POST | `/users` | Create a user — `{ "name": "Alice" }` |
| GET  | `/notifications?user_id=<id>` | List a user's notifications |
| POST | `/notifications` | Create a notification — `{ "user_id", "title", "body" }` |

---

## Operations script

`scripts/ops.sh` is the single entry point for working with the local stack. It uses
`set -euo pipefail`, checks that Docker is running, and prints actionable errors.

| Command | Action |
|---------|--------|
| `./scripts/ops.sh up` | Build + start the stack, wait for `/health` (idempotent) |
| `./scripts/ops.sh down` | Stop the stack (keeps the data volume) |
| `./scripts/ops.sh status` | Show container state + API health |
| `./scripts/ops.sh logs` | Tail the API logs |
| `./scripts/ops.sh smoke` | Create a user + notification and read them back |

`up` is safe to run repeatedly. If `.env` is missing it is created from `.env.example`.

---

## CI/CD

Workflow: [`.github/workflows/ci.yml`](.github/workflows/ci.yml)

**On every pull request to `main`:**
1. Build the image with Buildx (layers cached via GitHub Actions cache).
2. Scan the image with **Trivy** (fails on fixable `CRITICAL` CVEs).
3. Start the full stack with Compose.
4. Run the smoke test (`./scripts/ops.sh smoke`) — reusing the same script operators use.
5. Dump logs automatically if anything fails; always tear down.

**Additionally on push to `main`:**
6. Push the image to **GitHub Container Registry (GHCR)**, tagged `latest` and the full
   commit SHA.

**Notes**
- No credentials are committed. GHCR auth uses the automatic `GITHUB_TOKEN` with
  `packages: write` scoped to the publish job only.
- Fail-fast: a failing smoke test fails the job (`set -e` + non-zero exits propagate).
- Layer caching (`type=gha`) keeps PR builds fast and is reused by the publish job.

> After the first successful push to `main`, the package is private by default. Make it
> public via the repo's **Packages** page if you want anonymous `docker pull`.

---

## Cloud deployment (Render)

A [`render.yaml`](render.yaml) Blueprint deploys the API as a Docker web service plus a
managed PostgreSQL instance — both on Render's free tier.

**Steps**
1. Push this repo to GitHub.
2. In Render: **New → Blueprint**, select the repo. Render reads `render.yaml`.
3. It provisions `notifications-db` (Postgres) and `notifications-api` (web), wiring the
   `DB_*` env vars from the database automatically.
4. Render injects `$PORT`; the app already reads it. Health checks hit `/health`.

Once live: `curl https://<your-service>.onrender.com/health`.

> Free Postgres on Render expires after ~30 days and free web services sleep when idle —
> fine for a demo, not for production.

---

## Design decisions & trade-offs

- **Multi-stage Dockerfile** — dependencies install in a `deps` stage; the runtime image
  copies only `node_modules` + `src`. Smaller image, no build tooling in production.
- **`npm ci` + committed `package-lock.json`** — the starter shipped without a lockfile.
  I generated and committed one so builds are reproducible and `npm ci` can fail on drift.
- **Non-root + `tini`** — the container runs as the unprivileged `node` user, with `tini`
  as PID 1 for correct signal handling and zombie reaping (clean `Ctrl-C` / SIGTERM).
- **Health-gated startup ordering** — Postgres has a `pg_isready` healthcheck and the API
  uses `depends_on: condition: service_healthy`. This prevents the known failure where the
  API boots, can't reach the DB, and `initDb()` throws.
- **`/health` as the universal readiness signal** — reused by the image `HEALTHCHECK`,
  Compose, `ops.sh`, CI, and Render rather than inventing separate checks.
- **Reused smoke logic** — CI calls `./scripts/ops.sh smoke` instead of duplicating curl
  commands, so the operator path and the tested path are identical.
- **Config via environment** — no secrets in the image or repo; `.env` is git-ignored and
  only `.env.example` is committed.

## Assumptions

- Port **8080** locally (matches the brief's `curl` examples); Render overrides via `$PORT`.
- Default dev credentials (`app`/`app`) are fine for local Compose; real deployments inject
  real secrets via env vars / the platform's secret store.
- Trivy gates on `CRITICAL` (ignoring unfixed) to stay actionable without blocking PRs on
  unfixable base-image noise — severity is easy to tighten later.
- "Tail API logs" means following the API service logs (last 100 lines, `-f`).

## Project structure

```
.
├── Dockerfile               # multi-stage, non-root, healthcheck
├── docker-compose.yml       # api + postgres, network, volume, health-gated ordering
├── .dockerignore
├── .env.example             # config template (.env is git-ignored)
├── Makefile                 # convenience wrappers (make up/down/smoke/scan)
├── render.yaml              # Render Blueprint (cloud bonus)
├── scripts/
│   └── ops.sh               # up | down | status | logs | smoke
├── .github/workflows/
│   └── ci.yml               # PR: build+scan+smoke · main: push to GHCR
└── src/                     # provided app (unchanged)
```
