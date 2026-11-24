# state.json — what the last enable applied.

aidns_read_state() {
  if [[ ! -f "$AIDNS_STATE" ]]; then
    return 1
  fi
  return 0
}

aidns_state_primary() {
  [[ -f "$AIDNS_STATE" ]] || { echo ""; return; }
  aidns_json_get "$AIDNS_STATE" "primary" ""
}

aidns_state_primary_provider() {
  [[ -f "$AIDNS_STATE" ]] || { echo ""; return; }
  aidns_json_get "$AIDNS_STATE" "primaryProvider" ""
}

aidns_state_servers() {
  [[ -f "$AIDNS_STATE" ]] || { echo ""; return; }
  python3 - "$AIDNS_STATE" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    doc = json.load(f)
servers = doc.get("servers") or []
print(" ".join(str(s) for s in servers))
PY
}

aidns_known_smart_dns() {
  # Collect known smart DNS from state + catalog addresses passed as args
  local -a known=()
  if [[ -f "$AIDNS_STATE" ]]; then
    mapfile -t known < <(python3 - "$AIDNS_STATE" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    doc = json.load(f)
for s in doc.get("servers") or []:
    print(s)
for s in doc.get("allCandidateIps") or []:
    print(s)
if doc.get("primary"):
    print(doc["primary"])
PY
)
  fi
  local x
  for x in "$@"; do
    known+=("$x")
  done
  printf "%s\n" "${known[@]}" | awk 'NF' | sort -u
}

aidns_write_state() {
  local primary="$1"
  local provider="$2"
  shift 2
  local -a servers=("$@")
  local applied
  applied="$(aidns_now_iso)"
  local json
  json="$(python3 - "$applied" "$primary" "$provider" "${servers[@]}" <<'PY'
import json, sys
applied, primary, provider = sys.argv[1], sys.argv[2], sys.argv[3]
servers = sys.argv[4:]
doc = {
  "schemaVersion": 3,
  "applied": applied,
  "servers": servers,
  "primary": primary,
  "primaryProvider": provider,
  "nrpt": [],
  "dohAdded": [],
  "allCandidateIps": servers,
}
print(json.dumps(doc, ensure_ascii=False, indent=2))
PY
)"
  aidns_json_write "$AIDNS_STATE" "$json"
}

aidns_clear_cache() {
  if [[ -d "$AIDNS_CACHE" ]]; then
    aidns_system_change "Delete $AIDNS_CACHE" rm -rf "$AIDNS_CACHE"
  fi
  mkdir -p "$AIDNS_CACHE"
}

aidns_remove_data() {
  local keep_logs="${1:-0}"
  if [[ ! -d "$AIDNS_DATA_ROOT" ]]; then
    return 0
  fi
  if [[ "$keep_logs" -eq 1 ]]; then
    if [[ "$AIDNS_DRY_RUN" -eq 1 ]]; then
      aidns_note "Common.DryRunChange" "Delete $AIDNS_DATA_ROOT (except logs)"
      return 0
    fi
    local entry
    for entry in "$AIDNS_DATA_ROOT"/*; do
      [[ -e "$entry" ]] || continue
      [[ "$(basename "$entry")" == "logs" ]] && continue
      rm -rf "$entry" || return 1
    done
    return 0
  fi
  if [[ "$AIDNS_DRY_RUN" -eq 1 ]]; then
    aidns_note "Common.DryRunChange" "Delete $AIDNS_DATA_ROOT"
    return 0
  fi
  # Close log if it lives under data root
  if [[ -n "${AIDNS_LOG_FILE:-}" && "$AIDNS_LOG_FILE" == "$AIDNS_DATA_ROOT"* ]]; then
    AIDNS_LOG_FILE=""
  fi
  rm -rf "$AIDNS_DATA_ROOT" || return 1
}
