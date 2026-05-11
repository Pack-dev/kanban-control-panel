# scripts/

Operational scripts for the kanban stack.

## `dev.sh`

Brings up the backend (Go on `:8080`) and the frontend (Vite on `:5173`) together. Logs from each are prefixed (`[back] ...`, `[front] ...`). Ctrl-C tears both down.

Prereqs: submodules initialised, `backend/.env` present (copy from `backend/.env.example` and set `JWT_SECRET`).

```bash
./scripts/dev.sh
```

## `smoke.sh`

End-to-end happy-path test against the live API: register → board → columns → cards → drag → labels → checklist → cascade delete. 12 assertions; exits non-zero on any failure.

```bash
# Default targets http://localhost:8080
./scripts/smoke.sh

# Or against another instance:
API_URL=http://localhost:18181 ./scripts/smoke.sh
```

## `isolation.sh`

Cross-user authorization regression. Registers users A and B, has A create board/column/card/label/checklist, then verifies every mutating endpoint returns 404 when B targets A's resources (including the two cross-board special cases). 19 assertions.

```bash
./scripts/isolation.sh
```

Both QA scripts assume `jq` and `curl` are on PATH.
