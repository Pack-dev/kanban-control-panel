# Kanban — Phase 1 Retrospectives

Sprint-by-sprint retros for the Phase 1 build (2026-05-11). Mirrored to ClickUp under the same titles.

Each entry uses a compact **Shipped / Worked well / Didn't work / Lessons** structure.

---

## Sprint 0 — Pivot & scope (1 round)

**Shipped**
- Pivot decision from todo-list to kanban with the same stack.
- Interview-driven [`doc/spec.md`](./spec.md) (single-user, multiple boards, user-defined columns, drag-and-drop, hard delete, current stack kept, rich card fields).
- Task-level [`doc/plan.md`](./plan.md) breaking the spec into 7 milestones across the backend / frontend / qa subagent split.
- Three project-level subagents defined in `.claude/agents/` (backend, frontend, qa) with scoped tool access and skill hints (`/security-review`, `/review`, `/frontend-design`).

**Worked well**
- Interviewing in batched `AskUserQuestion` rounds (4 questions per round) with the recommended choice flagged. The user accepted defaults across the board → fast, decisive scoping.
- Capturing the spec **before** writing any code. Every later disagreement traced back to a missing line in the spec, not an implementation gap.

**Didn't work**
- The first batch of options included 5 multi-select choices, which hit the `AskUserQuestion` cap of 4. Cost one round-trip.

**Lessons**
- Keep multi-select option counts ≤ 4.
- A separate `doc/plan.md` from `doc/spec.md` is worth the duplication — the spec stays a clean product contract, the plan stays a build chronicle.

---

## Sprint 1 — Walking skeleton (M0 + M1 + M2 + M3)

**Shipped**
- M0: dropped the todo backend + frontend; installed `vuedraggable@next`, `marked`, `dompurify`; added a `useToast` composable + `ToastHost`.
- M1: kanban schema (`boards / columns / cards / labels / card_labels / checklist_items`) with cascade-delete coverage test.
- M2: boards / columns / cards CRUD handlers + cross-column move on `PUT /api/cards/:id`. 30 new tests including cross-user 404, cross-board same-user 404, empty-body PUT 400.
- M3: boards store, cards store, `Boards.vue`, `Board.vue`, `BoardColumn.vue`, `CardItem.vue`. Cards drag within and across columns, columns drag too.

**Worked well**
- **Parallel agent execution.** M0 backend, M0 frontend, and QA prep ran concurrently in non-overlapping directories. Then M2 backend + M3 frontend ran concurrently again, with frontend coding to the spec while backend was still being built.
- **Pre-writing QA scripts** before M2 / M3 landed meant integration verification was a single command, not a writing exercise.
- The `RegisterRoutes` helper that the backend agent introduced unified prod and test route tables — eliminated a memory-noted drift risk.

**Didn't work**
- Login.vue / Register.vue / router guard were left with dangling `{ name: 'todos' }` pushes after M0 frontend cleanup because the agent stayed strictly inside its scope. That became a one-line known issue we threaded through to T3.3.

**Lessons**
- Tight subagent scope is a feature, not a bug — but the parent must explicitly thread cross-scope cleanup tasks (the dangling-todo reference) into the next round's prompt.
- "Walking skeleton first" (drag + CRUD, no card modal) was the right MVP slice. Everything richer layered on cleanly.

---

## Sprint 2 — Rich features (M4 + M5)

**Shipped**
- M4 backend: label CRUD + per-card attach/detach with same-board enforcement, checklist items CRUD (`done` int 0/1), hydrated `GET /api/boards/:id` populates nested labels + checklist. 23 new tests.
- M5 frontend: `CardModal`, `MarkdownEditor`, `MarkdownView` (sanitised by `DOMPurify` with a strict allowlist), due date with chip variants, `LabelPickerPopover`, `ChecklistEditor` with drag-reorder.

**Worked well**
- Resolving three spec ambiguities (wire format conventions, cross-board 404 rule, component filename casing) **before** spawning M4/M5 paid for itself. Neither agent asked a clarification; both produced contract-aligned code.
- The agents proactively over-delivered: by the time we got to M6, T6.1 (filter), T6.2 (empty states), and most of T6.3 (drag-ghost styles + card transitions) were already shipped during M3/M5 polish.

**Didn't work**
- The M5 frontend agent assumed `T4.3` (hydrated GET populating labels + checklist) before that landed. Worked out because M4 backend ran in parallel and finished in the same round, but in a slower world it would have been a sync gap.

**Lessons**
- When two parallel agents have a producer/consumer relationship, make the dependency explicit in both prompts. "Backend M4 is in flight; if `GET /api/boards/:id` doesn't yet populate `labels[]` per card, gracefully degrade" would have been a sharper instruction.
- Sanitisation defaults matter: `DOMPurify` out of the box is permissive; the strict allowlist + `target=_blank` / `rel=noopener noreferrer` enforcement was worth the explicit prompt.

---

## Sprint 3 — Polish & QA (M6 + M7)

**Shipped**
- M6: leftover polish (column transitions, `prefers-reduced-motion` rules across the board).
- M7: live integration smoke (12/12) + cross-user isolation (19/19) + build verification (go test ~82% on handlers; `npm run build` clean).

**Worked well**
- Running M7 directly in the parent thread (after a couple of rejected agent spawns) was faster — the QA scripts were pre-written, just needed `bash` invocations.
- Two bugs in the throwaway QA scripts were caught and fixed (bash 3.2 array compat; `done: true` vs `done: 1` body — the backend correctly rejected the boolean per spec, exposing the script's bug not the backend's).

**Didn't work**
- The user rejected two agent spawns silently before "do next" again. Spent a round inferring that "do directly" was the preferred mode.

**Lessons**
- When the same instruction comes back unchanged after an interruption, default to doing the work directly rather than re-spawning the same agent shape.

---

## Sprint 4 — Iteration: bugfix, RBAC, retrospective

**Shipped**
- Diagnosed and fixed the **vuedraggable freeze** ("clicking add freezes the page"). Root cause: `:model-value` (computed) + `@update:model-value` (prop mutation) + `tag="transition-group"` created a reactive feedback loop on programmatic adds — 13 GETs in <1s, then the main thread stopped dispatching clicks. Fix: switch to vuedraggable's `:list` prop (direct in-place mutation), drop `tag="transition-group"`, drive filter visibility via `v-show`.
- Briefly shipped a 3-value card `status` enum (pending / in_progress / complete) with colored chip + modal selector — then reverted it on clarification (in kanban, the **columns** are the statuses).
- Shipped **global RBAC** (admin / user). First registered user becomes admin atomically; JWT carries `role`; `RequireAdmin` middleware returns **403** (intentional deviation from the cross-user 404 rule — see [`spec.md`](./spec.md) §5b). Admin endpoints: list users, set role, delete user, list all boards. Self-protection on demote / delete. `PROMOTE_EMAIL` env var for dev bootstrap. 11 new backend tests + `Admin.vue` frontend.
- Updated `CLAUDE.md` (was 100% todo-era) and `doc/spec.md` (added §5b RBAC + closed all open questions). Saved the vuedraggable trap to memory so a future session won't re-debug it.

**Worked well**
- Reading the backend access log to spot the pathological GET burst was the fastest path to the freeze diagnosis. The bug was 100% frontend, but the symptom showed up clearly in the server log.
- The `AskUserQuestion` clarification round on the requirement ambiguity ("columns ARE statuses; what do you want done with the redundant `status` field?") saved a round of misalignment.

**Didn't work**
- I implemented the fixed-enum `status` feature before recognising that it duplicated the column concept. Spent ~half a round on it, then reverted.

**Lessons**
- For features that look like they overlap with existing primitives, **state the existing primitive first** before asking what the new field does. "Columns are already user-defined statuses — are you asking to: (a) make those richer, (b) add an orthogonal classification like priority, or (c) something else?" would have caught the conflict before any code.
- Bug history that's hard to re-derive (the vuedraggable trap) belongs in memory. Bug history that's obvious from the code or commit (an off-by-one fix) doesn't.

---

## Phase 1 tally

- **Sprints**: 5 (Sprint 0 scope + Sprints 1–4).
- **Milestones**: M0 – M7, all shipped + RBAC layer on top.
- **Backend**: ~82% coverage on `internal/handlers`. Cross-user / cross-board 404 isolation verified by 19 regression assertions.
- **Frontend**: zero E2E tests (manual smoke only). One bug in production (vuedraggable freeze) caught and fixed during user testing.
- **Repos**: split from one workshop dir into three (kanban-backend, kanban-frontend, kanban-control-panel) at the end of Sprint 4.

## What I'd do differently next time

1. **Surface implicit overlaps earlier.** "Status" vs "columns" is the most obvious one in this build. The check-list: before adding a new field, name every existing primitive it might overlap with and ask the user which it replaces, augments, or is orthogonal to.
2. **Write Dockerfiles in the service repos**, not the orchestrator. Phase 2 work — the orchestrator currently uses native `dev.sh` rather than `docker compose`.
3. **Frontend tests.** Zero today; the vuedraggable freeze and the dangling-route-name bug would both have been caught by even a smoke-level Vitest pass.
4. **Single-source the spec earlier.** The "decisions back-ported during build" subsection in §10 is a tell that we shipped knowledge that should have been in the spec from the start (non-numeric id → 404, column actions on boards store, idempotent label re-attach).
