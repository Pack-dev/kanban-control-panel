# Kanban App — Phase 1 Plan

Date: 2026-05-11
Source spec: [`doc/spec.md`](./spec.md)
Supersedes: root `PLAN.md` (todo app — obsolete).

A task-level breakdown of the Phase 1 kanban build. Each task lists its owner (which subagent should pick it up), inputs, deliverables, acceptance criteria, dependencies, and a rough size (**S** ≤1h, **M** 1–3h, **L** 3–6h, **XL** >6h).

The plan is grouped into seven milestones. **M0–M3 form the walking skeleton** (boards, columns, cards CRUD with drag) — that is the first shippable slice. M4–M6 layer on rich card fields, and M7 is the QA pass.

---

## Subagent assignments

| Owner | Handles | Definition lives in |
|-------|---------|---------------------|
| `backend` | Anything under `backend/` — Go handlers, migrations, JWT, tests | `.claude/agents/backend.md` |
| `frontend` | Anything under `frontend/` — Vue components, Pinia stores, axios, styling | `.claude/agents/frontend.md` |
| `qa` | Verification only — runs servers, hits the API, runs builds and tests. Does **not** edit source. | `.claude/agents/qa.md` |

Custom subagents load at session start, so they'll be selectable as `subagent_type: backend|frontend|qa` after the next session restart.

---

## Dependency graph (high level)

```
M0 ─┬─► M1 ─► M2 ─► M3 ──► M6 ──► M7
    │                ▲
    │                │
    └────────►  M4 ──┴──► M5
```

- **M0** (cleanup) unblocks everything.
- **M1** (schema) unblocks all backend work.
- **M3** (frontend walking skeleton) depends on **M2** for the API.
- **M4** (rich backend) can run in parallel with **M3** once **M1** is done.
- **M5** (rich frontend) depends on both **M3** and **M4**.
- **M6** is polish — runs after **M3** + **M5**.
- **M7** is QA — runs at the end, but `qa` can run interim smoke tests after **M2** and **M3** land.

---

## M0 — Cleanup & scaffolding

Remove the todo app. Add the toast composable and the new frontend libraries. This is the only milestone that touches both sides.

### T0.1 — Drop todo backend
- **Owner**: `backend`
- **Size**: S
- **Deliverables**:
  - Remove `/api/todos` route registrations from `cmd/server/main.go`.
  - Delete `internal/handlers/todos*.go` and its tests.
  - Remove `CREATE TABLE todos ...` from the migration. (Schema change OK — there's no production data and a fresh `.db` will be regenerated.)
- **Acceptance**: `go build ./...` and `go test ./...` green from `backend/`. No symbol named `Todo` remains.
- **Depends on**: —

### T0.2 — Drop todo frontend
- **Owner**: `frontend`
- **Size**: S
- **Deliverables**:
  - Delete `frontend/src/stores/todos.js`, `frontend/src/views/TodosView.vue`, any todo-specific components.
  - Remove the `/todos` route from `src/router`.
- **Acceptance**: `npm run build` green from `frontend/`. No imports reference the deleted files.
- **Depends on**: —

### T0.3 — Toast composable
- **Owner**: `frontend`
- **Size**: M
- **Deliverables**:
  - `src/composables/useToast.js` exposing `success(msg)` / `error(msg)` and a reactive queue.
  - `src/components/ToastHost.vue` mounted once in `App.vue`; auto-dismiss after 3s; respects the shipped palette (success → `--good`, error → an accent-red token).
  - Animations use the existing `fade` transition.
- **Acceptance**: A throwaway button in `App.vue` (removed before commit) triggers a toast; visual check in `npm run dev`.
- **Depends on**: —

### T0.4 — Install new deps
- **Owner**: `frontend`
- **Size**: S
- **Deliverables**:
  - `npm install vuedraggable@next marked dompurify`
  - Versions pinned in `package.json`.
- **Acceptance**: `npm run build` still green; lockfile committed.
- **Depends on**: —

---

## M1 — Schema

One milestone, one task. Lays the foundation for everything backend.

### T1.1 — Kanban tables + indexes + cascade test
- **Owner**: `backend`
- **Size**: M
- **Deliverables**:
  - Add `CREATE TABLE IF NOT EXISTS` for `boards`, `columns`, `cards`, `labels`, `card_labels`, `checklist_items` in `internal/db` (see spec §4 for exact DDL).
  - Add the five indexes from spec §4.
  - Add `internal/models` (or extend existing) with structs: `Board`, `Column`, `Card`, `Label`, `ChecklistItem`. Match the SQLite column types — `done` is `int` 0/1, `position` is `float64`, `due_date` is `*string`.
  - Add a `db_test.go` that inserts a user → board → column → card → checklist item + card_label, then deletes the user and asserts every dependent row is gone. This is the **load-bearing test** for the spec's cascade promise.
- **Acceptance**: `go test ./internal/db/... -run Cascade` passes. Migration is idempotent (running twice doesn't error).
- **Depends on**: T0.1

---

## M2 — Backend walking skeleton (boards / columns / cards)

The minimum API surface needed for a usable kanban. Each task ships with handler tests covering happy path, validation error, auth required, and cross-user 404.

### T2.1 — Boards handlers
- **Owner**: `backend`
- **Size**: L
- **Deliverables**:
  - `GET /api/boards` → `{boards: [...]}` ordered by `position`.
  - `POST /api/boards` → bare board; `position` auto-appended (max + 1, or 1.0 if empty).
  - `GET /api/boards/:id` → **hydrated** board with nested `columns[].cards[]` (empty `labels`/`checklist` arrays — those land in M4) and a `labels[]` array.
  - `PUT /api/boards/:id` → patch `name?` and/or `position?`.
  - `DELETE /api/boards/:id`.
  - Tests for each + a cross-user 404 test (user B can't `GET`/`PUT`/`DELETE` user A's board).
- **Acceptance**: `go test ./internal/handlers/... -run Board` green. Manual `curl` round-trip from `qa` agent.
- **Depends on**: T1.1

### T2.2 — Columns handlers
- **Owner**: `backend`
- **Size**: M
- **Deliverables**:
  - `POST /api/boards/:boardId/columns` (verifies board ownership)
  - `PUT /api/columns/:id`, `DELETE /api/columns/:id` (verifies column → board → user chain)
  - Tests including cross-user 404 + cross-board column-id rejection.
- **Acceptance**: `go test ./internal/handlers/... -run Column` green.
- **Depends on**: T2.1

### T2.3 — Cards handlers (incl. cross-column move)
- **Owner**: `backend`
- **Size**: L
- **Deliverables**:
  - `POST /api/columns/:columnId/cards` with `{title, position}`. Returns bare card with empty `labels` / `checklist` arrays.
  - `PUT /api/cards/:id` with optional `{title?, description?, due_date?, position?, column_id?}`. **Critical**: when `column_id` is provided, the handler must verify the target column belongs to the **same board** (and therefore the same user). This is the load-bearing isolation check for drag-across-columns.
  - `DELETE /api/cards/:id`.
  - Tests: happy path; cross-user 404; cross-board `column_id` rejection where user owns both boards (user A moves a card from A's board 1 into a column of A's board 2 → **404** per spec §6 cross-board isolation); empty-body PUT → 400.
- **Acceptance**: `go test ./internal/handlers/... -run Card` green.
- **Depends on**: T2.2

### T2.4 — Wire routes
- **Owner**: `backend`
- **Size**: S
- **Deliverables**: All routes registered in `cmd/server/main.go` with auth middleware. The route table in tests stays in sync (per the memory note: route table is duplicated between `main.go` and `helpers_test.go` — fix or deduplicate while you're here).
- **Acceptance**: `go build ./...` green, server starts, all endpoints respond on `curl` with `401` when token is missing.
- **Depends on**: T2.1, T2.2, T2.3

---

## M3 — Frontend walking skeleton

Reach feature parity with M2's API surface in the UI. By the end, a user can register, create a board, manage columns, and drag cards.

### T3.1 — Boards store
- **Owner**: `frontend`
- **Size**: M
- **Deliverables**: `stores/boards.js` with `boards[]`, `currentBoard`, actions `fetchAll`, `create(name)`, `rename(id, name)`, `reorder(id, position)`, `remove(id)`, `open(id)` (hydrates `currentBoard`). All mutations follow the same optimistic-with-snapshot pattern documented in the `frontend_todos_store` memory.
- **Acceptance**: Manual: log in, call actions from the console, observe network + reactive state.
- **Depends on**: T0.2, T0.3, T2.1

### T3.2 — Boards list view
- **Owner**: `frontend`
- **Size**: M
- **Deliverables**: `Boards.vue` — list of boards (use shipped `.auth-card` style for visual continuity), create-board form, empty state CTA. Clicking a board navigates to `/boards/:id`.
- **Acceptance**: Visual check in browser; create / rename / delete round-trip.
- **Depends on**: T3.1

### T3.3 — Router updates
- **Owner**: `frontend`
- **Size**: S
- **Deliverables**:
  - Add `/boards` and `/boards/:id` to router. `/` redirects to `/boards`.
  - Login success redirects to `/boards`. Auth guard still kicks unauthenticated visitors to `/login`.
  - **Fix the dangling reference left by T0.2**: `Login.vue` and `Register.vue` currently call `router.push({ name: 'todos' })`. Retarget both to `{ name: 'boards' }`. Until this lands, the auth flow is broken at runtime — do not test login until T3.3 is complete.
  - Same for the guest-while-authenticated redirect in the router guard (also currently points at `{ name: 'todos' }`).
- **Acceptance**: Manual nav check; auth guard test (visit `/boards` without token → `/login`); successful login lands on `/boards`; `grep -r "name: 'todos'" frontend/src/` returns nothing.
- **Depends on**: T3.2

### T3.4 — Board view shell
- **Owner**: `frontend`
- **Size**: M
- **Deliverables**: `Board.vue` with top bar (board name, theme toggle, add-column button, filter input — wired in T6.1), horizontal scroller of columns. No drag yet. `BoardColumn.vue` renders column header (name, count, ⋯ menu) and a static list of `CardItem.vue` (title only).
- **Acceptance**: Visual: open a board, see columns and cards rendered.
- **Depends on**: T3.3, T2.2, T2.3

### T3.5 — Cards store
- **Owner**: `frontend`
- **Size**: L
- **Deliverables**: `stores/cards.js` (or extend `boards`) with `create`, `update`, `move(cardId, targetColumnId, targetPosition)`, `remove`. All optimistic with snapshot rollback + toast on error. `move` writes to local state immediately, then `PUT /api/cards/:id` with `{column_id, position}`.
- **Acceptance**: Manual round-trip in console (no UI yet); rollback test by forcing 500.
- **Depends on**: T3.4, T0.3

### T3.6 — Drag cards within a column
- **Owner**: `frontend`
- **Size**: M
- **Deliverables**: Wire `vuedraggable@next` on the card list inside `BoardColumn`. Compute new `position` as midpoint between neighbours; persist via `cards.update`.
- **Acceptance**: Drag a card up/down, reload page, order persists.
- **Depends on**: T3.5

### T3.7 — Drag cards across columns
- **Owner**: `frontend`
- **Size**: L
- **Deliverables**: Multi-list draggable with a shared `group` name across all columns on the board. On drop in a new column, call `cards.move(id, targetColumnId, position)`. Backend already supports this from T2.3.
- **Acceptance**: Drag card A from column 1 to column 2, reload, card stays in column 2 at the dropped position.
- **Depends on**: T3.6

### T3.8 — Drag columns within a board
- **Owner**: `frontend`
- **Size**: M
- **Deliverables**: Draggable on the columns scroller. Persists via `PUT /api/columns/:id` with new `position`.
- **Acceptance**: Drag a column, reload, order persists.
- **Depends on**: T3.7

---

## M4 — Backend rich features

Runs in parallel with M3. Schema is already in place from M1.

### T4.1 — Labels + card_labels handlers
- **Owner**: `backend`
- **Size**: M
- **Deliverables**:
  - `POST /api/boards/:boardId/labels`, `PUT /api/labels/:id`, `DELETE /api/labels/:id`.
  - `POST /api/cards/:id/labels` (attach), `DELETE /api/cards/:id/labels/:labelId` (detach).
  - Server-side validation: `color` must be one of `label-1` .. `label-8` (invalid → 400). Attach must verify the label belongs to the **same board** as the card (same-board check is the load-bearing isolation rule, mirroring T2.3). Cross-board attach/detach → **404** (not 400, not 403 — per spec §6).
  - Tests for each + cross-board attach rejection (user owns both boards) + cross-user 404 + empty-body PUT → 400.
- **Acceptance**: `go test ./internal/handlers/... -run Label` green.
- **Depends on**: T1.1

### T4.2 — Checklist items handlers
- **Owner**: `backend`
- **Size**: M
- **Deliverables**: `POST /api/cards/:cardId/checklist`, `PUT /api/checklist/:id`, `DELETE /api/checklist/:id`. `done` is INTEGER 0/1 (project convention). Position handling mirrors cards.
- **Acceptance**: `go test ./internal/handlers/... -run Checklist` green.
- **Depends on**: T1.1

### T4.3 — Update hydrated board endpoint
- **Owner**: `backend`
- **Size**: S
- **Deliverables**: `GET /api/boards/:id` now actually populates `labels` per card and `checklist` items per card (was empty in T2.1).
- **Acceptance**: Hydrated GET returns full nested data; test asserts a card with attached labels and checklist items round-trips.
- **Depends on**: T4.1, T4.2

---

## M5 — Frontend rich features

Depends on M4 for API + on M3 for the board view shell and cards store.

### T5.1 — Card modal shell
- **Owner**: `frontend`
- **Size**: M
- **Deliverables**: `CardModal.vue` opens on `CardItem` click. Title field + plain textarea description (markdown rendering comes in T5.2). Save / cancel / delete. Uses the shipped `fade` transition and a backdrop.
- **Acceptance**: Open card, edit title, save, observe update.
- **Depends on**: T3.5

### T5.2 — Markdown editor + sanitized render
- **Owner**: `frontend`
- **Size**: M
- **Deliverables**:
  - `MarkdownEditor.vue` — textarea + preview tab toggle.
  - `MarkdownView.vue` — renders via `marked`, sanitizes via `DOMPurify`. Allowed tags: `p`, `strong`, `em`, `ul`, `ol`, `li`, `a` (with `rel="noopener noreferrer"` enforced), `code`, `pre`, `blockquote`, `br`. Block all `<script>`, inline event handlers, `<img>` (for now), `<iframe>`.
- **Acceptance**: Paste `<script>alert(1)</script>` into description → renders as empty. Verify in browser.
- **Depends on**: T5.1, T0.4

### T5.3 — Due date
- **Owner**: `frontend`
- **Size**: M
- **Deliverables**: Native `<input type="date">` in `CardModal`. `CardItem` shows a due-date chip; near-due (≤2 days) gets a warning tint, overdue gets `--accent`-red.
- **Acceptance**: Set due date, observe chip; clear it; reload persists.
- **Depends on**: T5.1

### T5.4 — Label picker + chips
- **Owner**: `frontend`
- **Size**: L
- **Deliverables**:
  - `LabelPickerPopover.vue` — list of board labels, inline create (name + color picker from `label-1..8`), click to toggle on the current card.
  - Label chips render on `CardItem` (compact, color from `--label-N`).
  - Frontend store actions: `labels.create / update / remove`, `cards.attachLabel / detachLabel`.
- **Acceptance**: Create a label, attach to a card, see chip; detach; delete the label and confirm chip disappears from all cards.
- **Depends on**: T5.1, T4.1

### T5.5 — Checklist editor + progress
- **Owner**: `frontend`
- **Size**: L
- **Deliverables**:
  - `ChecklistEditor.vue` in `CardModal` — list of items with checkbox + text, add new at the bottom, drag to reorder (reuse `vuedraggable`).
  - `CardItem` shows `done/total` progress when the checklist is non-empty.
- **Acceptance**: Add 3 items, check 1, observe progress `1/3` on the card; reorder items; delete an item.
- **Depends on**: T5.1, T4.2

---

## M6 — Polish

### T6.1 — Filter
- **Owner**: `frontend`
- **Size**: S
- **Deliverables**: Filter input on `BoardView` top bar; hides cards whose `title + description` doesn't substring-match (case-insensitive). Purely frontend.
- **Acceptance**: Type a query, watch cards filter live.
- **Depends on**: T3.7

### T6.2 — Empty states
- **Owner**: `frontend`
- **Size**: S
- **Deliverables**: "Create your first board" on `BoardsView`; "Add your first column" placeholder column inside `BoardView`; dashed "Add a card" affordance inside each empty column.
- **Acceptance**: New account flow ends on an empty `BoardsView` with the CTA visible.
- **Depends on**: T3.2, T3.4

### T6.3 — Animations
- **Owner**: `frontend`
- **Size**: M
- **Deliverables**: Card-add slide-in, drag ghost (50% opacity + lifted shadow), checklist-strike micro-animation on toggle, gentle fade on delete. Reuse existing `fade` / `card` transitions where possible.
- **Acceptance**: Visual review in browser, both light and dark themes.
- **Depends on**: T3.7, T5.5

---

## M7 — QA & ship

### T7.1 — Manual smoke test
- **Owner**: `qa`
- **Size**: M
- **Deliverables**: A pass through the full happy path: register → create board → add 3 columns → add 5 cards → drag cards within column → drag cards across columns → drag columns → open card modal → set description + due date → create + attach 2 labels → add a 3-item checklist, check one → delete a card → delete a column → delete a board. Document each step's outcome.
- **Acceptance**: All steps pass with no console errors; a written checklist saved (or pasted into a comment).
- **Depends on**: M6 complete.

### T7.2 — Cross-user isolation regression
- **Owner**: `qa`
- **Size**: M
- **Deliverables**: Register users A and B. For every mutating endpoint (boards, columns, cards, labels, checklist), confirm B receives 404 when targeting A's resources. Special-case: attempt to move A's card into one of A's columns while authenticated as B (must 404), and attempt to attach one of A's labels to A's card while authenticated as B (must 404).
- **Acceptance**: Documented matrix — every endpoint × cross-user attempt → 404.
- **Depends on**: T7.1

### T7.3 — Build verification
- **Owner**: `qa`
- **Size**: S
- **Deliverables**: Run from clean state: `cd backend && go build ./... && go test ./... -count=1 -cover`. Run from clean state: `cd frontend && npm install && npm run build`. Capture exact output + exit codes.
- **Acceptance**: All commands exit 0; coverage on backend handlers ≥ what we had on the todo app (>76%).
- **Depends on**: T7.1

---

## Cross-cutting "definition of done"

Every task before being marked complete:

- [ ] Backend changes: `go build ./...` and `go test ./...` green from `backend/`.
- [ ] Frontend changes: `npm run build` green from `frontend/`. If interactive, also `npm run dev` browser check.
- [ ] No new lint / typecheck regressions (we currently have no lint config — leave it alone; don't introduce one in Phase 1).
- [ ] Endpoint changes update tests in the same task, not "later".
- [ ] No secrets committed; `.env` stays gitignored; `data/app.db` stays gitignored.
- [ ] Spec drift: if you discover the implementation has to deviate from `doc/spec.md`, update the spec **before** writing code (or in the same change).

---

## Tracking

Suggested tracking: a `TodoWrite` task list mirroring the IDs above (T0.1 .. T7.3). The `backend`, `frontend`, and `qa` subagents pick tasks by ID and update status when done.

## Out of scope (deferred to Phase 2)

Verbatim from spec §9, repeated here for the plan reader:

- Multi-user sharing, invites, roles.
- Real-time updates / WebSockets / cross-tab sync.
- WIP limits per column.
- Card archive / soft delete.
- Cross-board search.
- Activity log / audit trail.
- Attachments, comments, mentions.
- Mobile-optimized drag UX.
- Card cover images.

## Open items before kickoff

- Confirm `marked` + `DOMPurify` are acceptable (alternative: `micromark`).
- Confirm the existing palette tokens to use for label colors — the `frontend_styling_system` memory lists `--label-1..8`; this plan assumes those map 1:1 to the spec's color enum.
- Decide whether to delete or rewrite the obsolete root `PLAN.md` (currently still describing the todo app).
