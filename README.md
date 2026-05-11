# kanban-control-panel

Orchestrator for the **kanban** app. Holds the canonical product docs, the subagent definitions, the QA scripts, and a dev launcher that runs the whole stack with one command. The two service repos are wired in as git submodules.

```
kanban-control-panel/
├── README.md            # this file
├── CLAUDE.md            # full AI guidance for the whole project
├── doc/
│   ├── spec.md          # canonical Phase 1 product spec
│   ├── plan.md          # task-level build plan (M0 – M7)
│   └── retrospective.md # sprint-by-sprint retro (mirrored to ClickUp)
├── .claude/agents/
│   ├── backend.md       # backend specialist subagent
│   ├── frontend.md      # frontend specialist subagent
│   └── qa.md            # QA specialist subagent
├── scripts/
│   ├── dev.sh           # native dev — go run + npm run dev
│   ├── smoke.sh         # E2E API happy-path test (12 steps)
│   ├── isolation.sh     # cross-user authorization regression (19 checks)
│   └── README.md
├── docker-compose.yml   # production-style stack — nginx + backend
├── .env.example         # shared env template (JWT_SECRET, HOST_PORT, …)
├── .gitignore
├── backend              # → git submodule: kanban-backend (has Dockerfile)
└── frontend             # → git submodule: kanban-frontend (has Dockerfile + nginx.conf)
```

## Architecture at a glance

```
            ┌────────────────────────────────────┐
            │ kanban-control-panel               │
            │  - docs (spec / plan / retro)      │
            │  - agent defs                      │
            │  - QA scripts                      │
            │  - dev orchestration               │
            └──┬──────────────────────────────┬──┘
               │ submodule                    │ submodule
       ┌───────▼─────────┐            ┌───────▼─────────┐
       │ kanban-backend  │            │ kanban-frontend │
       │ Go + Gin + JWT  │  HTTP/JSON │ Vue 3 + Vite    │
       │ SQLite, RBAC    │ ◄──────────┤ Pinia, axios    │
       │ :8080           │            │ :5173 (dev)     │
       └─────────────────┘            └─────────────────┘
```

## Getting started

```bash
git clone --recursive https://github.com/Pack-dev/kanban-control-panel.git
cd kanban-control-panel

# If you forgot --recursive:
git submodule update --init --recursive
```

Pick one of the two run modes below.

### Option A — Production-style (docker compose)

Single port for users; nginx serves the SPA and proxies `/api/*` to the backend over the internal docker network. Persistent SQLite volume.

```bash
cp .env.example .env
# edit .env, set JWT_SECRET=<a long random string>

docker compose up --build
```

Then open **http://localhost:8080**. The backend container is NOT exposed to the host by default (only nginx is); uncomment the `ports:` block under `backend:` in `docker-compose.yml` if you want direct `curl http://localhost:8080/api/...` access.

Tear down:
```bash
docker compose down              # keeps the SQLite volume
docker compose down -v           # wipes the SQLite volume too
```

### Option B — Native dev (hot reload)

Best for active development. Runs `go run` and `npm run dev` together with prefixed logs.

```bash
cp backend/.env.example backend/.env
# edit backend/.env, set JWT_SECRET=<a long random string>

./scripts/dev.sh
```

Then:
- Frontend (Vite dev w/ HMR): http://localhost:5173
- Backend (Gin):              http://localhost:8080

The Vite dev server proxies `/api/*` to `:8080`.

---

The **first user to register** automatically becomes admin (atomic in a SQL transaction). To bootstrap admin access on an existing DB, set `PROMOTE_EMAIL=you@example.com` in `.env` (compose) or `backend/.env` (native) before starting the backend.

## Testing the live API

```bash
# In another terminal, with dev.sh running:
./scripts/smoke.sh        # 12-step end-to-end happy path
./scripts/isolation.sh    # 19-row cross-user 404 regression
```

Both target `http://localhost:8080` by default; override with `API_URL=...`.

## Docs

- [`doc/spec.md`](./doc/spec.md) — canonical product / API contract. The source of truth.
- [`doc/plan.md`](./doc/plan.md) — task-level build plan (M0 – M7 milestones).
- [`doc/retrospective.md`](./doc/retrospective.md) — sprint retros.
- [`CLAUDE.md`](./CLAUDE.md) — quick-reference for stack, env, conventions, and AI-pair-programming guidance.

## Service repos

- Backend: https://github.com/Pack-dev/kanban-backend
- Frontend: https://github.com/Pack-dev/kanban-frontend

To push updates to a service from inside the orchestrator:

```bash
cd backend
git checkout main
# ... make changes, commit, push to kanban-backend
cd ..
git add backend                  # the orchestrator now tracks the new commit
git commit -m "bump backend to <sha>"
git push
```

## Future work

- CI for each service repo (currently no GitHub Actions workflows).
- Frontend test suite (Vitest unit + component, plus an E2E pass).
- Push container images to a registry (currently they're built locally as `kanban-backend:local` / `kanban-frontend:local`).
- HTTPS termination (the nginx config terminates plain HTTP today).
