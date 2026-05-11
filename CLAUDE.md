# CLAUDE.md

Guidance for Claude Code when working in this repo.

## Project

A full-stack **kanban board** app with role-based access control.

- **Backend**: Go (Gin) REST API, **Postgres** via `pgx/v5` (database/sql compat), JWT auth, RBAC (admin / user).
- **Frontend**: Vue 3 (Vite, Pinia, Vue Router), custom pastel + dark-mode styling, drag-and-drop.

The repo started as a todo-list and was **pivoted to kanban on 2026-05-11**. Phase 1 (M0–M7) is complete.

**Canonical contract lives in [`doc/spec.md`](./doc/spec.md); task-level breakdown in [`doc/plan.md`](./doc/plan.md).** Treat those as the source of truth for behavior; CLAUDE.md is the quick-reference for conventions, env, and commands.

## Layout

```
backend/    Go API server   (cmd/server, internal/{auth,handlers,middleware,models,db,config})
frontend/   Vue 3 SPA       (src/{api,stores,router,views,components,composables,assets})
doc/        spec.md + plan.md (canonical product / build docs)
.claude/    subagent definitions (backend, frontend, qa)
```

Backend serves JSON on `/api/*`. Frontend is a separate Vite dev server during development.

## Backend

- Framework: `github.com/gin-gonic/gin`
- DB driver: `github.com/jackc/pgx/v5/stdlib` (Postgres, database/sql compat)
- JWT: `github.com/golang-jwt/jwt/v5`
- Password hashing: `golang.org/x/crypto/bcrypt`
- Env loading: `github.com/joho/godotenv`

### Env vars (see `backend/.env.example`)
- `PORT` — HTTP port (default 8080)
- `JWT_SECRET` — required, used to sign tokens
- `DATABASE_URL` — **required**, Postgres URL (`postgres://user:pw@host:5432/dbname?sslmode=disable`)
- `TEST_DATABASE_URL` — Postgres URL used by `go test`. Unset → integration tests skip. Each test creates and drops its own schema, so this user needs `CREATE` / `DROP SCHEMA` privilege.
- `CORS_ORIGIN` — frontend origin for CORS (default `http://localhost:5173`)
- `PROMOTE_EMAIL` — **optional, dev convenience.** On startup, promotes the matching user (by email) to admin. Useful when an existing DB pre-dates RBAC. No-op if the email doesn't exist.

### Commands (run from `backend/`)
```bash
go mod tidy
go run ./cmd/server         # start API
go build -o bin/server ./cmd/server
go test ./... -count=1 -cover
```

### API surface — quick reference

Full contract is in `doc/spec.md` §6. Brief table:

| Method | Path                                    | Auth   | Notes                                     |
|--------|-----------------------------------------|--------|-------------------------------------------|
| POST   | `/api/auth/register`                    | no     | first user becomes admin                  |
| POST   | `/api/auth/login`                       | no     | response includes `user.role`             |
| POST   | `/api/auth/logout`                      | yes    | no-op token-invalidate                    |
| GET    | `/api/boards`                           | yes    | list (own boards only)                    |
| POST   | `/api/boards`                           | yes    | create                                    |
| GET    | `/api/boards/:id`                       | yes    | **hydrated**: columns→cards→labels+checklist |
| PUT    | `/api/boards/:id`                       | yes    | rename / reposition                       |
| DELETE | `/api/boards/:id`                       | yes    | cascades through columns / cards          |
| POST   | `/api/boards/:id/columns`               | yes    | create column                             |
| PUT    | `/api/columns/:id`                      | yes    | rename / reposition                       |
| DELETE | `/api/columns/:id`                      | yes    | cascade                                   |
| POST   | `/api/columns/:id/cards`                | yes    | create card                               |
| PUT    | `/api/cards/:id`                        | yes    | patch + cross-column move (`column_id`)   |
| DELETE | `/api/cards/:id`                        | yes    | cascade                                   |
| POST   | `/api/boards/:id/labels`                | yes    | create label on a board                   |
| PUT    | `/api/labels/:id`                       | yes    | rename / recolor                          |
| DELETE | `/api/labels/:id`                       | yes    | cascades `card_labels`                    |
| POST   | `/api/cards/:id/labels`                 | yes    | attach (same-board only)                  |
| DELETE | `/api/cards/:id/labels/:labelId`        | yes    | detach                                    |
| POST   | `/api/cards/:id/checklist`              | yes    | add checklist item                        |
| PUT    | `/api/checklist/:id`                    | yes    | edit / toggle `done` (int 0/1)            |
| DELETE | `/api/checklist/:id`                    | yes    | delete item                               |
| GET    | `/api/admin/users`                      | **admin** | list every user + board count          |
| PUT    | `/api/admin/users/:id/role`             | **admin** | change role (`admin` or `user`)        |
| DELETE | `/api/admin/users/:id`                  | **admin** | cascades through boards / cards        |
| GET    | `/api/admin/boards`                     | **admin** | list every board across users          |

Auth header: `Authorization: Bearer <token>`. Errors use `{ "error": "<message>" }`.

### Schema

```sql
users(id, email UNIQUE, password_hash, role DEFAULT 'user', created_at)
boards(id, user_id FK→users, name, position, created_at, updated_at)
columns(id, board_id FK→boards, name, position, created_at, updated_at)  -- table name "columns" is reserved; always quote
cards(id, column_id FK→columns, title, description, due_date NULL, position, created_at, updated_at)
labels(id, board_id FK→boards, name, color, created_at)
card_labels(card_id FK→cards, label_id FK→labels, PRIMARY KEY (card_id, label_id))
checklist_items(id, card_id FK→cards, text, done INT 0/1, position, created_at)
```

Concrete column types: `id`/`*_id` are `BIGSERIAL`/`BIGINT`, `position` is `DOUBLE PRECISION`, `users.created_at` is `TIMESTAMPTZ DEFAULT NOW()` (auto-populated), all other `created_at`/`updated_at` columns are `TEXT` carrying RFC 3339 strings via `nowISO()`. `"columns"` is double-quoted (COLUMN is reserved).

All FKs cascade. Postgres enforces foreign keys natively. Migrations run on startup: `CREATE TABLE IF NOT EXISTS` + `CREATE INDEX IF NOT EXISTS` + `ALTER TABLE ADD COLUMN IF NOT EXISTS` (Postgres 9.6+).

### RBAC

- `users.role` is `'admin'` or `'user'`, default `'user'`.
- **First registered user becomes admin** automatically (atomic via `BEGIN; SELECT COUNT(*); INSERT; COMMIT;` so concurrent first-registrations don't both claim it).
- JWT claims include `role`; `RequireAuth` puts it on the gin context as `middleware.ContextRole`.
- **`RequireAdmin` returns 403, not 404.** Deliberate deviation from the cross-user 404 convention: the resource lives at a known URL and the *role* is what's wrong — not the resource's identity. Cross-user/cross-board access still returns 404 (never leak existence).
- Admins cannot demote or delete themselves (400). All other admin/admin transitions are allowed.
- `PROMOTE_EMAIL=foo@bar.com go run ./cmd/server` will bootstrap admin access for an existing user once.

## Frontend

- Vue 3 Composition API, `<script setup>` everywhere.
- Vite, Pinia, Vue Router 4, Axios.
- Drag-and-drop: `vuedraggable@next` with the `:list` prop (mutates the array in place). **Do not use `:model-value` + `@update:model-value` + `tag="transition-group"` together — that combo deadlocks under reactive parent mutations.** (Bug history kept in memory.)
- Markdown: `marked` + `DOMPurify` (tight allowlist; XSS-safe).
- Auth token + user JSON kept in `localStorage`. Axios request interceptor injects `Authorization`. Response interceptor on 401 clears session and hard-redirects to `/login`.
- `useTheme()` composable controls `data-theme` attribute on `<html>`; FOUC-prevention script sets it before paint.

### Commands (run from `frontend/`)
```bash
npm install
npm run dev        # http://localhost:5173 (proxies /api → 8080)
npm run build
npm run preview
```

### Pages
- `/login`, `/register` — public
- `/boards` — protected; list / create / rename / delete boards
- `/boards/:id` — protected; columns + cards, drag within and across columns, column drag, card modal with markdown + due date + labels + checklist
- `/admin` — protected + admin-only; user table (promote / demote / delete) + all-boards table

### Styling
Custom CSS with CSS-custom-property palette (paper / ink / accent / good / warn / label-1..8 / shadow-card / etc), light + dark themes, transitions `fade` and `card`, utility classes `.btn`, `.form`, `.auth-card`. No UI kit. Respects `prefers-reduced-motion`.

## Conventions

- **Backend**: idiomatic Go, thin handlers, business logic in `internal/db`. Tests live alongside handlers under `internal/handlers/*_test.go`; shared test helpers in `helpers_test.go`. Use `RegisterRoutes` (the one source of truth) — both `cmd/server/main.go` and tests go through it.
- **Frontend**: small components, lift state to Pinia stores. Optimistic-with-snapshot-rollback pattern for every mutation; surface failures via `useToast().error(...)`.
- **Wire format**:
  - Booleans on the wire = integer `0`/`1` (not JSON true/false).
  - Dates = `YYYY-MM-DD` strings, or `null` to clear.
  - Timestamps = ISO 8601 strings, server-generated.
  - Empty-body `PUT` → 400.
- **Status codes**: cross-user / cross-board violations → **404** (no existence leak). RBAC role denial → **403**.
- Don't commit any `.env` file (DBs are managed externally now — no local file to leak).
- SQL: positional placeholders `$1, $2, …` (Postgres). Inserts use `RETURNING id` + `QueryRow().Scan(&id)`, NOT `LastInsertId`. Idempotent inserts use `INSERT ... ON CONFLICT DO NOTHING`. Unique-violation detection is SQLSTATE `23505` via `pgconn.PgError` (see `handlers/auth.go` `isUniqueViolation`).

## Status

Phase 1 (M0 – M7) is complete. Deferred to a future phase (see `doc/spec.md` §9): multi-user **board sharing** with per-board roles (orthogonal to the global admin/user RBAC that *is* shipped), real-time sync, WIP limits, soft-delete / archive, cross-board search, activity log / audit trail, attachments, mobile-optimized drag UX.

When adding features, update `doc/spec.md` first (or in the same change), then implement. Keep this file (`CLAUDE.md`) accurate as a quick reference; if a section drifts from `doc/spec.md`, the spec wins.
