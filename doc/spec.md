# Kanban App — Phase 1 Spec

Date: 2026-05-11 (last revised same day; RBAC + retrospective sync)
Status: **Shipped.** All milestones M0–M7 complete. RBAC layered on top.

## 1. Overview

A kanban app with global RBAC. Each user has many boards; each board has user-defined columns; each column has cards with title, markdown description, due date, labels, and a checklist. Cards (and columns) reorder via drag-and-drop. Hard delete throughout. **Two roles** — `admin` and `user` — gate a small set of admin-only endpoints; regular boards remain owner-scoped (no per-board sharing in this phase). No real-time collaboration.

## 2. Stack

Unchanged from the todo app, plus two new libraries:

- **Backend** — Go, Gin, `modernc.org/sqlite`, `golang-jwt/jwt/v5`, `bcrypt`, `godotenv`.
- **Frontend** — Vue 3 (`<script setup>`), Vite, Pinia, Vue Router 4, Axios.
- **New**: `vuedraggable@next` (drag-and-drop), `marked` + `DOMPurify` (markdown render + sanitize).

## 3. Pivot from todo app

- Drop the `todos` table; replace with `boards / columns / cards / labels / card_labels / checklist_items`.
- Keep the `users` table, auth handlers, JWT middleware, axios client, theme system, router guard, and the `.btn` / `.form` / `.auth-card` utility classes.
- Remove `/api/todos`, `frontend/src/views/TodosView.vue`, `frontend/src/stores/todos.js`.
- Login / register responses keep their current shape `{token, user: {id, email}}` — the frontend auth store already depends on it.

## 4. Data model

### Tables

```sql
-- existing table; one additive column for RBAC
users(id, email UNIQUE, password_hash, role TEXT NOT NULL DEFAULT 'user', created_at)
-- role enum: 'admin' | 'user'. See §5b for semantics.

boards(
  id          INTEGER PRIMARY KEY,
  user_id     INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name        TEXT NOT NULL,
  position    REAL NOT NULL,         -- sidebar order
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL
)

columns(
  id          INTEGER PRIMARY KEY,
  board_id    INTEGER NOT NULL REFERENCES boards(id) ON DELETE CASCADE,
  name        TEXT NOT NULL,
  position    REAL NOT NULL,         -- left-to-right order in board
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL
)

cards(
  id          INTEGER PRIMARY KEY,
  column_id   INTEGER NOT NULL REFERENCES columns(id) ON DELETE CASCADE,
  title       TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',   -- markdown
  due_date    TEXT NULL,                  -- ISO 8601 date (YYYY-MM-DD)
  position    REAL NOT NULL,              -- top-to-bottom within column
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL
)

labels(
  id          INTEGER PRIMARY KEY,
  board_id    INTEGER NOT NULL REFERENCES boards(id) ON DELETE CASCADE,
  name        TEXT NOT NULL,
  color       TEXT NOT NULL,              -- enum: label-1 .. label-8 (maps to CSS tokens)
  created_at  TEXT NOT NULL
)

card_labels(
  card_id   INTEGER NOT NULL REFERENCES cards(id)  ON DELETE CASCADE,
  label_id  INTEGER NOT NULL REFERENCES labels(id) ON DELETE CASCADE,
  PRIMARY KEY (card_id, label_id)
)

checklist_items(
  id          INTEGER PRIMARY KEY,
  card_id     INTEGER NOT NULL REFERENCES cards(id) ON DELETE CASCADE,
  text        TEXT NOT NULL,
  done        INTEGER NOT NULL DEFAULT 0, -- 0/1, matches project convention
  position    REAL NOT NULL,
  created_at  TEXT NOT NULL
)
```

### Indexes

```sql
CREATE INDEX idx_boards_user_id      ON boards(user_id);
CREATE INDEX idx_columns_board_id    ON columns(board_id);
CREATE INDEX idx_cards_column_id     ON cards(column_id);
CREATE INDEX idx_labels_board_id     ON labels(board_id);
CREATE INDEX idx_checklist_card_id   ON checklist_items(card_id);
```

### Notes

- `position` is `REAL` so fractional reinsertion (`(prev + next) / 2`) avoids re-numbering siblings on every drag. A periodic compaction routine can rebalance if values get too close (out of scope for Phase 1).
- All deletes cascade through the chain `users → boards → columns → cards → {card_labels, checklist_items}`. SQLite's `foreign_keys=1` pragma is already enabled in the DSN — keep it.
- Migrations stay as idempotent `CREATE TABLE IF NOT EXISTS` + `CREATE INDEX IF NOT EXISTS` in `internal/db`. No migration framework.

## 5. Auth

| Method | Path                  | Auth | Body                               | Returns                                       |
|--------|-----------------------|------|------------------------------------|-----------------------------------------------|
| POST   | `/api/auth/register`  | no   | `{email, password}`                | `{token, user: {id, email, role}}`            |
| POST   | `/api/auth/login`     | no   | `{email, password}`                | `{token, user: {id, email, role}}`            |
| POST   | `/api/auth/logout`    | yes  | —                                  | `{ok: true}`                                  |

`Authorization: Bearer <token>`. JWT claims: `uid`, `email`, **`role`**, 24h TTL. Error shape: `{"error": "<message>"}`. Cross-user resource access returns **404** (does not reveal existence). RBAC role denial returns **403** — see §5b.

## 5b. RBAC

A small, global role system layered on the per-user ownership model. Two roles only: `admin` and `user`.

### Roles

- Stored on `users.role` (TEXT, NOT NULL, default `'user'`).
- Included in JWT claims; the gin context exposes the role via `middleware.ContextRole`.
- Per-row board / column / card ownership is **unchanged** by role — admins do not see other users' boards through the normal `/api/boards` endpoint; admin visibility is restricted to dedicated `/api/admin/*` routes.

### Bootstrap

- **First registered user becomes admin**, atomically (the registration handler does `BEGIN; SELECT COUNT(*) FROM users; INSERT … role=<computed>; COMMIT;` so two concurrent first-registrations cannot both claim the admin slot).
- Optional dev convenience: `PROMOTE_EMAIL=<email>` env var. On server startup, the matching user is set to `role='admin'`. No-op if the email is not found. Documented for re-seeding admin access in a pre-RBAC DB.

### Admin endpoints

All require `Authorization: Bearer <token>` **AND** `role='admin'`. Unauthorized role → **403** (not 404 — see "403 vs 404" below).

| Method | Path                              | Body                | Returns                                                              |
|--------|-----------------------------------|---------------------|----------------------------------------------------------------------|
| GET    | `/api/admin/users`                | —                   | `{users: [{id, email, role, created_at, board_count}, ...]}`         |
| PUT    | `/api/admin/users/:id/role`       | `{role}`            | `{ok: true, id, role}`                                               |
| DELETE | `/api/admin/users/:id`            | —                   | `{ok: true}` (cascades through boards / columns / cards / labels)    |
| GET    | `/api/admin/boards`               | —                   | `{boards: [{id, name, user_id, user_email, created_at}, ...]}`       |

### Self-action protection

- An admin **cannot demote themselves** (`PUT /api/admin/users/:selfId/role` with `role != 'admin'` → 400 `{"error":"admins cannot demote themselves"}`).
- An admin **cannot delete themselves** (`DELETE /api/admin/users/:selfId` → 400). Both guards exist to avoid locking the system out of admin access.
- Role-enum validation: `role` body must be exactly `"admin"` or `"user"` — anything else → 400.

### 403 vs 404 — explicit deviation from §6's cross-board rule

Cross-user / cross-board violations elsewhere in the spec return **404** to avoid leaking existence. RBAC denial uses **403** instead. Rationale: the admin endpoint's URL is well-known and documented; the resource the admin operates on (the *user list*, the *all-boards list*) is unambiguously identified by URL alone. What's wrong on denial is the *caller's role*, not the resource's identity. 403 communicates that accurately and consistently with HTTP semantics. This is the only place in the API where authorization failure surfaces as 403 rather than 404.

### Frontend

- `auth` store exposes a reactive `role` and `isAdmin` getter.
- Router gates `/admin` behind `meta: { requiresAdmin: true }`; non-admins are redirected to `/boards` (not shown the page even briefly).
- `NavBar` shows an `admin` link and an `admin` role-tag chip when `auth.isAdmin` is true.
- `Admin.vue` view: users table (email / role pill / board count / joined / promote–demote–delete) + all-boards table (name / owner email / created). Self-rows have promote/demote/delete disabled.

## 6. API — boards / columns / cards

All routes below require auth. Ownership is enforced by joining up the chain to `boards.user_id`. Status codes: 200 OK / 201 Created / 400 bad body / 401 unauthorized / 404 not-found-or-not-yours / 409 conflict / 500 internal.

### Wire-format conventions

These rules apply to **every** endpoint in this section unless explicitly overridden by a row:

- **Booleans / done flags** (e.g. `checklist_items.done`): integer `0` / `1` over the wire — not JSON `true`/`false`. Matches the project's existing convention (originating from `todos.done`) and the `INTEGER` storage type. Go struct fields are `int`.
- **Timestamps** (`created_at`, `updated_at`): ISO 8601 strings. Server-generated; never client-supplied.
- **IDs**: integers. Server-assigned; never client-supplied.
- **`position`**: float64. Client-supplied on POST (except `POST /api/boards`, see Boards table) and on PUTs that reorder.
- **`due_date`**: ISO 8601 date string `YYYY-MM-DD`, or `null` / omitted to clear.
- **Empty-body PUTs return 400** with `{"error":"at least one field must be provided"}`. Applies to every `PUT` route below.
- **Cross-board isolation**: any operation that references a resource owned by another user, **or that references a resource in a different board than the parent resource**, returns **404**. Never 400, never 403, never leaks existence. This rule covers (at minimum):
  - `PUT /api/cards/:id` with a `column_id` whose column lives in a different board → 404.
  - `POST /api/cards/:id/labels` with a `label_id` whose label lives in a different board than the card → 404.
  - `DELETE /api/cards/:id/labels/:labelId` where the label was never on the card, or lives in a different board → 404.
- **Unparseable path ids → 404** (not 400). A path segment like `/api/boards/abc` cannot reference an owned resource, so it returns 404 with the standard error envelope — consistent with the "never leak existence" rule.

### Boards

| Method | Path                | Body                  | Returns                                                                                  |
|--------|---------------------|-----------------------|------------------------------------------------------------------------------------------|
| GET    | `/api/boards`       | —                     | `{boards: [{id, name, position, created_at, updated_at}, ...]}` ordered by `position`     |
| POST   | `/api/boards`       | `{name}`              | bare board (position auto-appended to end)                                                |
| GET    | `/api/boards/:id`   | —                     | **hydrated**: `{id, name, position, columns: [{..., cards: [{..., labels:[], checklist:[]}]}], labels: [...]}` |
| PUT    | `/api/boards/:id`   | `{name?, position?}`  | bare board                                                                                |
| DELETE | `/api/boards/:id`   | —                     | `{ok: true}`                                                                              |

`GET /api/boards/:id` is the **one** hydration endpoint — the frontend calls it once on board entry and then mutates the local store optimistically.

### Columns

| Method | Path                                | Body                  | Returns       |
|--------|-------------------------------------|-----------------------|---------------|
| POST   | `/api/boards/:boardId/columns`      | `{name, position}`    | bare column   |
| PUT    | `/api/columns/:id`                  | `{name?, position?}`  | bare column   |
| DELETE | `/api/columns/:id`                  | —                     | `{ok: true}`  |

### Cards

| Method | Path                                  | Body                                                          | Returns       |
|--------|---------------------------------------|---------------------------------------------------------------|---------------|
| POST   | `/api/columns/:columnId/cards`        | `{title, position}`                                           | bare card with empty `labels` / `checklist` arrays |
| PUT    | `/api/cards/:id`                      | `{title?, description?, due_date?, position?, column_id?}`    | bare card     |
| DELETE | `/api/cards/:id`                      | —                                                             | `{ok: true}`  |

`column_id` in `PUT /api/cards/:id` is what powers cross-column drag — the same endpoint handles reorder *and* move. The handler must verify the target column belongs to the **same board** as the card (and therefore the same user). Violation → **404** (per the cross-board isolation rule above), not 400.

### Labels

| Method | Path                              | Body                | Returns       |
|--------|-----------------------------------|---------------------|---------------|
| POST   | `/api/boards/:boardId/labels`     | `{name, color}`     | bare label    |
| PUT    | `/api/labels/:id`                 | `{name?, color?}`   | bare label    |
| DELETE | `/api/labels/:id`                 | —                   | `{ok: true}`  |
| POST   | `/api/cards/:id/labels`           | `{label_id}`        | `{ok: true}`  |
| DELETE | `/api/cards/:id/labels/:labelId`  | —                   | `{ok: true}`  |

`color` is validated server-side against the enum `label-1` .. `label-8`. Invalid color → 400.

`POST /api/cards/:id/labels` and `DELETE /api/cards/:id/labels/:labelId` must verify the label belongs to the same board as the card. Cross-board attach/detach → **404**.

### Checklist items

| Method | Path                                  | Body                            | Returns       |
|--------|---------------------------------------|---------------------------------|---------------|
| POST   | `/api/cards/:cardId/checklist`        | `{text, position}`              | bare item     |
| PUT    | `/api/checklist/:id`                  | `{text?, done?, position?}`     | bare item     |
| DELETE | `/api/checklist/:id`                  | —                               | `{ok: true}`  |

## 7. Frontend

### Routes

| Path             | Auth | Purpose                                                 |
|------------------|------|---------------------------------------------------------|
| `/login`         | no   | unchanged                                               |
| `/register`      | no   | unchanged                                               |
| `/boards`        | yes  | list / create boards; landing page after login           |
| `/boards/:id`    | yes  | board view (columns, cards, drag-and-drop)              |

Router guard behavior unchanged: unauthenticated users hitting a protected route → `/login`.

### Stores (Pinia)

- `auth` — **unchanged**. Contract documented in memory (`frontend_auth_and_axios.md`).
- `boards` — `boards[]` (sidebar list), `currentBoard` (hydrated). Actions: `fetchAll`, `create`, `rename`, `reorder`, `remove`, `open(id)` (hydrates currentBoard), **plus column actions** `addColumn`, `renameColumn`, `removeColumn`, `reorderColumn` — these live on the boards store rather than a separate `columns` store because they mutate `currentBoard.columns[]` directly. Rationale: keeps reactivity dependencies tight and avoids two stores writing to the same nested array.
- `cards` — actions: `create`, `update`, `move(cardId, targetColumnId, targetPosition)`, `remove`, plus (in M4/M5) `attachLabel`, `detachLabel`, and checklist mutations. All mutations follow the existing optimistic-with-snapshot-rollback pattern from `stores/todos.js`.
- `labels`, `checklist` — nested actions on the `cards` store (no separate stores).

### Views and components

- `Boards.vue` — board list, create-board form, empty state.
- `Board.vue` — top bar (board name, filter input, theme toggle, add-column button), horizontal scroller of `BoardColumn`.
- `BoardColumn.vue` — column header (name, card count, ⋯ menu for rename/delete), draggable card list, add-card input at bottom.
- `CardItem.vue` — compact card. Shows title, due-date chip, label chips, checklist progress (`3/5`). Click → opens modal.
- `CardModal.vue` — full edit: title, markdown description (`MarkdownEditor`), due date picker, label picker, checklist editor, delete button.
- `MarkdownEditor.vue` — textarea with a `MarkdownView` preview tab. Render via `marked`, sanitize via `DOMPurify`.
- `LabelPickerPopover.vue` — list of board labels, create-label inline, toggle on/off the current card.
- `ChecklistEditor.vue` — list of items with checkbox + text, add new at bottom, drag to reorder.

### UX details

- **Drag-and-drop** uses `vuedraggable@next`. Cards drag within and across columns; columns drag within the board.
- **Filter** is purely frontend: a text input above the board hides cards whose `title + description` doesn't substring-match the query (case-insensitive). No backend search in Phase 1.
- **Empty states**:
  - New user → `/boards` shows "Create your first board" CTA.
  - New board → "Add your first column" placeholder column.
  - Empty column → dashed "Add a card" affordance.
- **Style** — reuse shipped tokens. New surfaces map as:
  - Card background = `--paper`, shadow = `--shadow-1`, border-radius matches `.auth-card`.
  - Label chip color = `--label-1..8` from the palette.
  - Drag ghost = 50% opacity, `--shadow-2` lifted.
  - Animations: existing `fade` and `card` transitions; add a `strike` micro-animation on checklist toggle.
  - Theme switching, `data-theme` attribute, and `useTheme()` composable stay as-is.

### Optimistic update contract (per action)

| Action               | Strategy                                                              |
|----------------------|-----------------------------------------------------------------------|
| create card / column | server-roundtrip first (server assigns id), then insert locally        |
| update / move        | snapshot → mutate locally → API → on error: restore snapshot + toast   |
| delete               | snapshot → remove locally → API → on error: restore + toast            |
| toggle checklist     | flip locally → API → on error: flip back + toast                       |

A toast component is **new for Phase 1** — the current todo app silently swallows mutation errors. Add a minimal `useToast()` composable with `success` / `error` variants.

## 8. Phase 1 build order

1. **Backend schema** — drop `todos`; create `boards / columns / cards / labels / card_labels / checklist_items` + indexes in `internal/db`. Verify cascade with a test.
2. **Backend boards** — handlers + tests (create / list / get hydrated / update / delete; cross-user isolation).
3. **Backend columns** — handlers + tests.
4. **Backend cards** — CRUD + cross-column move + tests. This is the most-tested handler in the project.
5. **Backend labels + card_labels** — handlers + tests; color enum validation.
6. **Backend checklist** — handlers + tests.
7. **Frontend teardown** — remove `stores/todos.js`, `views/TodosView.vue`, todos route. Add toast composable.
8. **Frontend boards** — `boards` store, `/boards` view, sidebar.
9. **Frontend board view + drag** — `BoardView`, `BoardColumn`, `CardItem`, `vuedraggable` wiring for cards-within-column and across-columns. Persist position via `PUT /api/cards/:id`.
10. **Frontend card modal** — title, markdown description (`marked` + `DOMPurify`), due date.
11. **Frontend labels** — picker + chips.
12. **Frontend checklist** — editor + progress on `CardItem`.
13. **Frontend filter + empty states + polish** — text filter, empty CTAs, animations.
14. **QA pass** — `go build`, `go test ./...`, `npm run build`, manual smoke: register → create board → add columns → add cards → drag → edit → delete; second user can't see first user's boards.

The first shippable slice (a "walking skeleton") is steps **1 – 4 + 7 – 9**: boards, columns, cards CRUD with drag. The remaining steps layer on incrementally without schema or API breakage.

## 9. Out of scope (deferred)

Shipped now (was previously listed as deferred): **global admin/user RBAC** — see §5b.

Still deferred:

- **Per-board sharing** with owner / editor / viewer roles. Orthogonal to the global RBAC we have — the admin role gates *system administration*, not collaborative editing.
- Invites / member management for shared boards.
- Real-time updates / WebSockets / cross-tab sync.
- WIP limits per column (schema-compatible — `wip_limit INTEGER NULL` is an additive change).
- Card archive / soft delete (additive `archived_at` column later).
- Cross-board search (backend endpoint).
- Activity log / audit trail.
- Attachments, comments, mentions.
- Mobile-optimized drag UX (current responsive baseline is the floor; touch drag may need a polish pass).
- Card cover images, custom card colors beyond labels.

## 10. Open questions

None remaining. Items resolved during Phase 1:

- ✅ `marked` + `DOMPurify` confirmed and shipped (strict allowlist; XSS-safe).
- ✅ Label color enum (`label-1..8`) maps 1:1 to existing palette tokens.
- ✅ Root `PLAN.md` (the legacy todo-list plan) is obsolete; `doc/plan.md` is canonical.

Decisions back-ported into the spec during build that future readers should know about:

- **Non-numeric path id → 404** (not 400). An unparseable `:id` can't reference an owned resource, so it returns 404 with the standard envelope — consistent with the "never leak existence" rule (§6).
- **Column mutation actions live on the `boards` store**, not a separate `columns` store. They mutate `currentBoard.columns[]`; co-locating keeps reactivity dependencies tight (§7).
- **Card labels and checklist arrays** are always returned by `POST /api/columns/:id/cards` and `PUT /api/cards/:id` — empty arrays for fresh cards. The frontend depends on those fields existing.
- **Idempotent re-attach**: `POST /api/cards/:id/labels` with a label already on the card returns **200** (via `INSERT OR IGNORE`), not 409. Drag-driven UIs may retry on transient failures; treating a no-op as success is the sensible behavior.
