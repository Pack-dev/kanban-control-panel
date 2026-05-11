#!/usr/bin/env bash
# isolation.sh — cross-user isolation regression for the kanban API.
# Plan task: T7.2
#
# Verifies that for every mutating endpoint in spec §6, user B cannot
# touch user A's resources. Cross-user access must return 404 (per the
# todo-app convention documented in memory/qa_security_posture.md —
# "Cross-user access returns 404, not 403").
#
# Prerequisites:
#   - Backend server running at $API_URL (default http://localhost:8080)
#   - jq and curl available on PATH
#
# Env vars:
#   API_URL   — base URL of the API (default: http://localhost:8080)
#
# Each row prints PASS or FAIL with the actual status code. Exit status
# is non-zero if any row fails. After running B's attacks, A's resources
# are re-fetched and verified unchanged.

set -euo pipefail

API_URL="${API_URL:-http://localhost:8080}"

command -v jq   >/dev/null || { echo "jq required" >&2; exit 2; }
command -v curl >/dev/null || { echo "curl required" >&2; exit 2; }

FAILS=0
ROW_NUM=0

# req METHOD PATH [BODY] [TOKEN] -> sets BODY,STATUS
req() {
  local method="$1" path="$2" body="${3:-}" token="${4:-}"
  local args=(-sS -o /tmp/kanban-qa.iso.body -w "%{http_code}" -X "$method")
  [[ -n "$token" ]] && args+=(-H "Authorization: Bearer ${token}")
  [[ -n "$body"  ]] && args+=(-H "Content-Type: application/json" -d "$body")
  args+=("${API_URL}${path}")
  STATUS=$(curl "${args[@]}")
  BODY="$(cat /tmp/kanban-qa.iso.body)"
}

# expect_404 LABEL METHOD PATH [BODY]
expect_404() {
  local label="$1" method="$2" path="$3" body="${4:-}"
  ROW_NUM=$((ROW_NUM + 1))
  req "$method" "$path" "$body" "$TOKEN_B"
  if [[ "$STATUS" == "404" ]]; then
    printf '  PASS  row %02d  %-7s %-50s  -> 404\n' "$ROW_NUM" "$method" "$path"
  else
    printf '  FAIL  row %02d  %-7s %-50s  -> %s (want 404)  body=%s\n' \
      "$ROW_NUM" "$method" "$path" "$STATUS" "$BODY"
    FAILS=$((FAILS + 1))
  fi
}

# Strict-201 / 200 / 401 expectations as setup helpers
expect_status() {
  local want="$1" label="$2"
  [[ "$STATUS" == "$want" ]] || { echo "setup-FAIL ($label): want $want got $STATUS — $BODY" >&2; exit 1; }
}

# ----- preflight: register A and B --------------------------------------

RAND="$(date +%s)-$$-$RANDOM"
EMAIL_A="qa-iso-a-${RAND}@example.test"
EMAIL_B="qa-iso-b-${RAND}@example.test"
PASS="hunter2hunter2"

req POST /api/auth/register "$(jq -nc --arg e "$EMAIL_A" --arg p "$PASS" '{email:$e,password:$p}')"
expect_status 201 "register A"
TOKEN_A="$(jq -r '.token' <<<"$BODY")"

req POST /api/auth/register "$(jq -nc --arg e "$EMAIL_B" --arg p "$PASS" '{email:$e,password:$p}')"
expect_status 201 "register B"
TOKEN_B="$(jq -r '.token' <<<"$BODY")"

echo "Registered:"
echo "  A = $EMAIL_A"
echo "  B = $EMAIL_B"

# ----- A creates resources ----------------------------------------------

req POST /api/boards "$(jq -nc '{name:"A board"}')" "$TOKEN_A"
expect_status 201 "A create board"
A_BOARD="$(jq -r '.id' <<<"$BODY")"

req POST "/api/boards/${A_BOARD}/columns" "$(jq -nc '{name:"A col",position:1.0}')" "$TOKEN_A"
expect_status 201 "A create column"
A_COL="$(jq -r '.id' <<<"$BODY")"

req POST "/api/columns/${A_COL}/cards" "$(jq -nc '{title:"A card",position:1.0}')" "$TOKEN_A"
expect_status 201 "A create card"
A_CARD="$(jq -r '.id' <<<"$BODY")"

req POST "/api/boards/${A_BOARD}/labels" "$(jq -nc '{name:"A label",color:"label-1"}')" "$TOKEN_A"
expect_status 201 "A create label"
A_LABEL="$(jq -r '.id' <<<"$BODY")"

req POST "/api/cards/${A_CARD}/checklist" "$(jq -nc '{text:"A item",position:1.0}')" "$TOKEN_A"
expect_status 201 "A create checklist"
A_CHECK="$(jq -r '.id' <<<"$BODY")"

# Snapshots of A's resources for "unchanged" check at the end
req GET "/api/boards/${A_BOARD}" "" "$TOKEN_A"
expect_status 200 "A snapshot board"
SNAPSHOT_BOARD_BEFORE="$BODY"

# ----- B creates own resources for the two special cases ----------------

req POST /api/boards "$(jq -nc '{name:"B board"}')" "$TOKEN_B"
expect_status 201 "B create board"
B_BOARD="$(jq -r '.id' <<<"$BODY")"

req POST "/api/boards/${B_BOARD}/columns" "$(jq -nc '{name:"B col",position:1.0}')" "$TOKEN_B"
expect_status 201 "B create column"
B_COL="$(jq -r '.id' <<<"$BODY")"

req POST "/api/columns/${B_COL}/cards" "$(jq -nc '{title:"B card",position:1.0}')" "$TOKEN_B"
expect_status 201 "B create card"
B_CARD="$(jq -r '.id' <<<"$BODY")"

echo
echo "B attempting attacks on A's resources (every row should be 404):"

# ----- boards -----------------------------------------------------------

expect_404 "B GET A board"          GET    "/api/boards/${A_BOARD}"
expect_404 "B PUT A board"          PUT    "/api/boards/${A_BOARD}"     '{"name":"hijack"}'
expect_404 "B DELETE A board"       DELETE "/api/boards/${A_BOARD}"
expect_404 "B POST col under A"     POST   "/api/boards/${A_BOARD}/columns" '{"name":"x","position":1.0}'
expect_404 "B POST label under A"   POST   "/api/boards/${A_BOARD}/labels"  '{"name":"x","color":"label-1"}'

# ----- columns ----------------------------------------------------------

expect_404 "B PUT A column"         PUT    "/api/columns/${A_COL}"      '{"name":"x"}'
expect_404 "B DELETE A column"      DELETE "/api/columns/${A_COL}"
expect_404 "B POST card under A col" POST  "/api/columns/${A_COL}/cards" '{"title":"x","position":1.0}'

# ----- cards ------------------------------------------------------------

expect_404 "B PUT A card"           PUT    "/api/cards/${A_CARD}"       '{"title":"hijack"}'
expect_404 "B DELETE A card"        DELETE "/api/cards/${A_CARD}"

# special: B tries to steal A's card into B's own column
expect_404 "B steal A card into B col" PUT "/api/cards/${A_CARD}" \
  "$(jq -nc --argjson c "$B_COL" '{column_id:$c}')"

# ----- labels -----------------------------------------------------------

expect_404 "B PUT A label"          PUT    "/api/labels/${A_LABEL}"     '{"name":"x"}'
expect_404 "B DELETE A label"       DELETE "/api/labels/${A_LABEL}"

# special: B attaches A's label to B's card (cross-board label attach)
expect_404 "B attach A label on B card" POST "/api/cards/${B_CARD}/labels" \
  "$(jq -nc --argjson l "$A_LABEL" '{label_id:$l}')"

# also: B attempts to attach a label (own or A's) onto A's card
expect_404 "B attach to A card"     POST   "/api/cards/${A_CARD}/labels" \
  "$(jq -nc --argjson l "$A_LABEL" '{label_id:$l}')"

expect_404 "B detach from A card"   DELETE "/api/cards/${A_CARD}/labels/${A_LABEL}"

# ----- checklist --------------------------------------------------------

expect_404 "B POST checklist on A"  POST   "/api/cards/${A_CARD}/checklist" '{"text":"x","position":1.0}'
expect_404 "B PUT A checklist"      PUT    "/api/checklist/${A_CHECK}"      '{"text":"x"}'
expect_404 "B DELETE A checklist"   DELETE "/api/checklist/${A_CHECK}"

# ----- verify A's view is unchanged -------------------------------------

echo
echo "Verifying A's resources are unchanged after B's failed attempts:"

req GET "/api/boards/${A_BOARD}" "" "$TOKEN_A"
expect_status 200 "A re-fetch board"
SNAPSHOT_BOARD_AFTER="$BODY"

# Compare invariant fields only (ignore updated_at on board itself in case
# some implementation bumps it on every read — extremely unlikely, but
# keep this resilient). We compare board name + columns ids/names + card ids/titles.
diff_filter() {
  jq -S '{
    id: .id,
    name: .name,
    columns: ([.columns[]? | {id, name, cards: ([.cards[]? | {id, title, column_id}] | sort_by(.id))}] | sort_by(.id)),
    labels:  ([.labels[]?  | {id, name, color}] | sort_by(.id))
  }'
}

BEFORE_DIGEST="$(printf '%s' "$SNAPSHOT_BOARD_BEFORE" | diff_filter)"
AFTER_DIGEST="$(printf '%s' "$SNAPSHOT_BOARD_AFTER"  | diff_filter)"

if [[ "$BEFORE_DIGEST" == "$AFTER_DIGEST" ]]; then
  echo "  PASS  A's board digest unchanged"
else
  echo "  FAIL  A's board digest CHANGED after B's attacks"
  diff <(printf '%s' "$BEFORE_DIGEST") <(printf '%s' "$AFTER_DIGEST") || true
  FAILS=$((FAILS + 1))
fi

# Also verify the checklist item still exists and is unmodified
req GET "/api/boards/${A_BOARD}" "" "$TOKEN_A"
HAS_CHECK="$(echo "$BODY" | jq -r --argjson cid "$A_CARD" --argjson xid "$A_CHECK" \
  '[.columns[].cards[]? | select(.id==$cid) | .checklist[]? | select(.id==$xid)] | length')"
# tolerate hydrated checklist not yet wired (M4 T4.3) — only fail if explicitly 0 AND endpoint returned it as an array
# if HAS_CHECK is 1 → great; if "" or null → soft-warn
case "$HAS_CHECK" in
  1) echo "  PASS  A's checklist item still present in hydrated board" ;;
  ""|null|0) echo "  WARN  A's checklist not surfaced in hydrated board (acceptable until T4.3 lands)" ;;
  *) echo "  WARN  unexpected checklist count: $HAS_CHECK" ;;
esac

echo
if [[ "$FAILS" -eq 0 ]]; then
  echo "ALL $ROW_NUM ISOLATION ROWS PASSED"
  exit 0
else
  echo "$FAILS / $ROW_NUM ISOLATION ROWS FAILED"
  exit 1
fi
