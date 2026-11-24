# Load and apply linux/settings.json (subset of Windows settings schema).

AIDNS_SETTING_LANGUAGE="Auto"
AIDNS_SETTING_LOG_DIRECTORY=""
AIDNS_SETTING_WAIT_SECONDS=20
AIDNS_SETTING_DISABLE_IPV6=1
AIDNS_SETTING_HOSTS=1
AIDNS_SETTING_PINNED_PROVIDER=""
AIDNS_SETTING_FLAG_TEST_ONLY=0
AIDNS_SETTING_FLAG_DRY_RUN=0
AIDNS_SETTING_FLAG_TRACE=0
AIDNS_SETTING_FLAG_OFFLINE=0
AIDNS_SETTING_FLAG_FULL=0
AIDNS_SETTING_FLAG_ENABLE_IPV6=0

declare -A AIDNS_MODE_OVERRIDE=()
AIDNS_CUSTOM_RESOLVERS=()
AIDNS_BLOCKED_PROVIDERS=()
AIDNS_BLOCKED_ADDRESSES=()
AIDNS_CUSTOM_SERVICES_JSON="[]"

aidns_default_settings_json() {
  cat <<'EOF'
{
  "schemaVersion": 1,
  "language": "Auto",
  "logDirectory": "",
  "waitSeconds": 20,
  "checkUpdates": false,
  "flags": {
    "testOnly": false,
    "dryRun": false,
    "trace": false,
    "offline": false,
    "full": false,
    "enableIPv6": false
  },
  "system": {
    "disableIpv6": true,
    "hosts": true
  },
  "modes": {
    "chatgpt": "Required",
    "claude": "Required",
    "gemini": "Preferred",
    "openai-api": "Preferred",
    "anthropic-api": "Preferred",
    "gemini-api": "Preferred",
    "code-login": "Preferred",
    "code-site": "Preferred",
    "code-updates": "Preferred"
  },
  "customServices": [],
  "customResolvers": [],
  "blockedProviders": [],
  "blockedAddresses": [],
  "pinnedProvider": ""
}
EOF
}

aidns_ensure_settings_file() {
  if [[ ! -f "$AIDNS_SETTINGS" ]]; then
    aidns_default_settings_json >"$AIDNS_SETTINGS"
  fi
}

aidns_bool_to_int() {
  case "${1,,}" in
    true|1|yes|on) echo 1 ;;
    *) echo 0 ;;
  esac
}

aidns_load_settings() {
  aidns_ensure_settings_file
  local f="$AIDNS_SETTINGS"

  AIDNS_SETTING_LANGUAGE="$(aidns_json_get "$f" "language" "Auto")"
  AIDNS_SETTING_LOG_DIRECTORY="$(aidns_json_get "$f" "logDirectory" "")"
  AIDNS_SETTING_WAIT_SECONDS="$(aidns_json_get "$f" "waitSeconds" "20")"
  AIDNS_SETTING_DISABLE_IPV6="$(aidns_bool_to_int "$(aidns_json_get "$f" "system.disableIpv6" "true")")"
  AIDNS_SETTING_HOSTS="$(aidns_bool_to_int "$(aidns_json_get "$f" "system.hosts" "true")")"
  AIDNS_SETTING_PINNED_PROVIDER="$(aidns_json_get "$f" "pinnedProvider" "")"

  AIDNS_SETTING_FLAG_TEST_ONLY="$(aidns_bool_to_int "$(aidns_json_get "$f" "flags.testOnly" "false")")"
  AIDNS_SETTING_FLAG_DRY_RUN="$(aidns_bool_to_int "$(aidns_json_get "$f" "flags.dryRun" "false")")"
  AIDNS_SETTING_FLAG_TRACE="$(aidns_bool_to_int "$(aidns_json_get "$f" "flags.trace" "false")")"
  AIDNS_SETTING_FLAG_OFFLINE="$(aidns_bool_to_int "$(aidns_json_get "$f" "flags.offline" "false")")"
  AIDNS_SETTING_FLAG_FULL="$(aidns_bool_to_int "$(aidns_json_get "$f" "flags.full" "false")")"
  AIDNS_SETTING_FLAG_ENABLE_IPV6="$(aidns_bool_to_int "$(aidns_json_get "$f" "flags.enableIPv6" "false")")"

  AIDNS_MODE_OVERRIDE=()
  while IFS=$'\t' read -r sid smode; do
    [[ -z "$sid" ]] && continue
    AIDNS_MODE_OVERRIDE["$sid"]="$smode"
  done < <(python3 - "$f" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
for k, v in (data.get("modes") or {}).items():
    if v in ("Required", "Preferred", "Off"):
        print(f"{k}\t{v}")
PY
)

  mapfile -t AIDNS_CUSTOM_RESOLVERS < <(python3 - "$f" <<'PY'
import json, sys, re
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
pat = re.compile(r"^(?:\d{1,3}\.){3}\d{1,3}$")
for ip in data.get("customResolvers") or []:
    s = str(ip).strip()
    if pat.match(s):
        print(s)
PY
)

  mapfile -t AIDNS_BLOCKED_PROVIDERS < <(python3 - "$f" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
for x in data.get("blockedProviders") or []:
    print(str(x).strip())
PY
)

  mapfile -t AIDNS_BLOCKED_ADDRESSES < <(python3 - "$f" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
for x in data.get("blockedAddresses") or []:
    print(str(x).strip())
PY
)

  AIDNS_CUSTOM_SERVICES_JSON="$(python3 - "$f" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
print(json.dumps(data.get("customServices") or [], ensure_ascii=False))
PY
)"

  aidns_apply_settings_to_services
}

aidns_apply_settings_to_services() {
  local -a out=()
  local row id mode
  for row in "${AIDNS_BUILTIN_SERVICES[@]}"; do
    id="$(aidns_service_field "$row" 0)"
    mode="$(aidns_service_field "$row" 1)"
    if [[ -n "${AIDNS_MODE_OVERRIDE[$id]:-}" ]]; then
      mode="${AIDNS_MODE_OVERRIDE[$id]}"
      # rebuild row with new mode (field 1)
      local name domain weight group kind region claude checks
      name="$(aidns_service_field "$row" 2)"
      domain="$(aidns_service_field "$row" 3)"
      weight="$(aidns_service_field "$row" 4)"
      group="$(aidns_service_field "$row" 5)"
      kind="$(aidns_service_field "$row" 6)"
      region="$(aidns_service_field "$row" 7)"
      claude="$(aidns_service_field "$row" 8)"
      checks="$(aidns_service_field "$row" 9)"
      row="$id|$mode|$name|$domain|$weight|$group|$kind|$region|$claude|$checks"
    fi
    out+=("$row")
  done

  # custom services: {id,name,domain,mode}
  while IFS=$'\t' read -r cid cname cdomain cmode; do
    [[ -z "$cid" ]] && continue
    [[ "$cmode" != "Required" && "$cmode" != "Preferred" && "$cmode" != "Off" ]] && cmode="Required"
    out+=("$cid|$cmode|$cname|$cdomain|100|Custom|Strict||0|/cdn-cgi/trace,8192;;/,65536")
  done < <(python3 -c '
import json,sys,re
dom=re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$", re.I)
data=json.loads(sys.argv[1])
n=0
for s in data:
    if n>=16: break
    domain=str(s.get("domain") or "").strip().lower().rstrip(".")
    if not domain or not dom.match(domain): continue
    sid=str(s.get("id") or ("custom-"+domain.replace(".","-")))[:32]
    name=str(s.get("name") or domain)[:40]
    mode=str(s.get("mode") or "Required")
    print(f"{sid}\t{name}\t{domain}\t{mode}")
    n+=1
' "$AIDNS_CUSTOM_SERVICES_JSON")

  AIDNS_SERVICES=("${out[@]}")
}

aidns_merge_setting_flags() {
  local action="$1"
  if [[ "$action" == "Enable" && "$AIDNS_SETTING_FLAG_TEST_ONLY" -eq 1 ]]; then AIDNS_TEST_ONLY=1; fi
  if [[ "$AIDNS_SETTING_FLAG_DRY_RUN" -eq 1 && "$action" != "Status" ]]; then AIDNS_DRY_RUN=1; fi
  if [[ "$AIDNS_SETTING_FLAG_TRACE" -eq 1 ]]; then AIDNS_TRACE=1; fi
  if [[ "$AIDNS_SETTING_FLAG_OFFLINE" -eq 1 && ( "$action" == "Enable" || "$action" == "Update" ) ]]; then AIDNS_OFFLINE=1; fi
  if [[ "$AIDNS_SETTING_FLAG_FULL" -eq 1 && ( "$action" == "Disable" || "$action" == "Update" ) ]]; then AIDNS_FULL=1; fi
  if [[ "$AIDNS_SETTING_FLAG_ENABLE_IPV6" -eq 1 && ( "$action" == "Disable" || "$action" == "Update" ) ]]; then AIDNS_ENABLE_IPV6=1; fi
}
