# Shared paths, elevation, logging and dry-run helpers for the Linux port.

set -euo pipefail

AIDNS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AIDNS_LIB="$AIDNS_ROOT/lib"
AIDNS_SHARE="$AIDNS_ROOT/share"
AIDNS_REPO_SRC="$(cd "$AIDNS_ROOT/../src" && pwd)"

AIDNS_DATA_ROOT="${AIDNS_DATA_ROOT:-/var/lib/aidns}"
AIDNS_CACHE="$AIDNS_DATA_ROOT/cache"
AIDNS_LOGS_DEFAULT="$AIDNS_DATA_ROOT/logs"
AIDNS_BACKUP="$AIDNS_DATA_ROOT/backup.json"
AIDNS_STATE="$AIDNS_DATA_ROOT/state.json"
AIDNS_HOSTS_BACKUP="$AIDNS_DATA_ROOT/hosts.bak"
AIDNS_RESOLVED_BACKUP="$AIDNS_DATA_ROOT/resolved.conf.bak"
AIDNS_SETTINGS="$AIDNS_ROOT/settings.json"
AIDNS_CATALOG="$AIDNS_REPO_SRC/providers.json"
AIDNS_HOSTS_FILE="/etc/hosts"
AIDNS_RESOLVED_CONF="/etc/systemd/resolved.conf"

AIDNS_HOSTS_MARKER="# AIDNS-disabled: "
AIDNS_RESOLVED_BEGIN="# AIDNS-begin"
AIDNS_RESOLVED_END="# AIDNS-end"
AIDNS_LOG_RETENTION=20
AIDNS_MODULE_VERSION="3.0.0-linux"

# Run flags (set by ai-dns.sh)
AIDNS_ACTION=""
AIDNS_TEST_ONLY=0
AIDNS_DRY_RUN=0
AIDNS_TRACE=0
AIDNS_FULL=0
AIDNS_ENABLE_IPV6=0
AIDNS_OFFLINE=0
AIDNS_LANGUAGE="Auto"
AIDNS_LOG_DIRECTORY=""
AIDNS_NO_WAIT=0
AIDNS_ERRORS=0
AIDNS_LOG_FILE=""
AIDNS_STARTED_AT=""
AIDNS_LANG="en"

# Color codes
AIDNS_C_RESET=$'\033[0m'
AIDNS_C_GREEN=$'\033[32m'
AIDNS_C_YELLOW=$'\033[33m'
AIDNS_C_RED=$'\033[31m'
AIDNS_C_CYAN=$'\033[36m'
AIDNS_C_GRAY=$'\033[90m'
AIDNS_C_WHITE=$'\033[37m'

aidns_is_root() {
  [[ "$(id -u)" -eq 0 ]]
}

aidns_require_root() {
  if ! aidns_is_root; then
    aidns_fail "Error.NotElevated"
    return 1
  fi
}

aidns_ensure_writable_cache() {
  if mkdir -p "$AIDNS_CACHE" 2>/dev/null; then
    return 0
  fi
  AIDNS_CACHE="$AIDNS_ROOT/cache"
  if mkdir -p "$AIDNS_CACHE" 2>/dev/null; then
    return 0
  fi
  AIDNS_CACHE="/tmp/aidns-cache"
  mkdir -p "$AIDNS_CACHE"
}

aidns_ensure_data_dirs() {
  aidns_ensure_writable_cache
  mkdir -p "$AIDNS_LOGS_DEFAULT" 2>/dev/null || true
}

aidns_now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%S"
}

aidns_elapsed() {
  local now started
  now=$(date +%s)
  started=${AIDNS_STARTED_AT:-$now}
  echo $((now - started))
}

# --- i18n ---

declare -A AIDNS_STRINGS=()

aidns_load_strings() {
  local lang="$1"
  AIDNS_STRINGS=()
  # shellcheck source=/dev/null
  source "$AIDNS_SHARE/strings-en.sh"
  if [[ "$lang" == "ru" ]]; then
    # shellcheck source=/dev/null
    source "$AIDNS_SHARE/strings-ru.sh"
  fi
}

aidns_resolve_language() {
  local requested="${1:-Auto}"
  if [[ "$requested" == "en" || "$requested" == "ru" ]]; then
    echo "$requested"
    return
  fi
  local from_settings="${AIDNS_SETTING_LANGUAGE:-Auto}"
  if [[ "$from_settings" == "en" || "$from_settings" == "ru" ]]; then
    echo "$from_settings"
    return
  fi
  local loc="${LANG:-}${LC_MESSAGES:-}${LC_ALL:-}"
  if [[ "$loc" == ru* || "$loc" == *".RU"* || "$loc" == *"ru_"* ]]; then
    echo "ru"
  else
    echo "en"
  fi
}

aidns_text() {
  local key="$1"
  shift || true
  local fmt="${AIDNS_STRINGS[$key]:-$key}"
  if [[ $# -gt 0 ]]; then
    # shellcheck disable=SC2059
    printf "$fmt" "$@"
  else
    printf "%s" "$fmt"
  fi
}

# --- logging ---

aidns_log_record() {
  local level="$1"
  shift
  local msg="$*"
  local line
  line="$(date '+%Y-%m-%d %H:%M:%S') [$level] $msg"
  if [[ -n "${AIDNS_LOG_FILE:-}" ]]; then
    printf "%s\n" "$line" >>"$AIDNS_LOG_FILE" || true
  fi
}

aidns_raw_line() {
  local msg="$1"
  local color="${2:-}"
  local level="${3:-INFO}"
  if [[ -n "$color" ]]; then
    printf "%s%s%s\n" "$color" "$msg" "$AIDNS_C_RESET"
  else
    printf "%s\n" "$msg"
  fi
  aidns_log_record "$level" "$msg"
}

aidns_ok() {
  local key="$1"; shift || true
  aidns_raw_line "  ✓ $(aidns_text "$key" "$@")" "$AIDNS_C_GREEN" "OK"
}

aidns_fail() {
  local key="$1"; shift || true
  AIDNS_ERRORS=$((AIDNS_ERRORS + 1))
  aidns_raw_line "  ✗ $(aidns_text "$key" "$@")" "$AIDNS_C_RED" "FAIL"
}

aidns_warn() {
  local key="$1"; shift || true
  aidns_raw_line "  ! $(aidns_text "$key" "$@")" "$AIDNS_C_YELLOW" "WARN"
}

aidns_note() {
  local key="$1"; shift || true
  aidns_raw_line "  · $(aidns_text "$key" "$@")" "$AIDNS_C_GRAY" "NOTE"
}

aidns_step() {
  local key="$1"; shift || true
  printf "\n"
  aidns_raw_line "== $(aidns_text "$key" "$@") ==" "$AIDNS_C_CYAN" "STEP"
}

aidns_trace() {
  if [[ "$AIDNS_TRACE" -eq 1 ]]; then
    aidns_raw_line "  [trace] $*" "$AIDNS_C_GRAY" "TRACE"
  else
    aidns_log_record "TRACE" "$*"
  fi
}

aidns_init_log() {
  local action="$1"
  local dir="${AIDNS_LOG_DIRECTORY:-$AIDNS_LOGS_DEFAULT}"
  if ! mkdir -p "$dir" 2>/dev/null; then
    dir="${AIDNS_LOG_DIRECTORY:-$AIDNS_ROOT/logs}"
    if ! mkdir -p "$dir" 2>/dev/null; then
      dir="/tmp/aidns-logs"
      mkdir -p "$dir"
    fi
  fi
  local stamp
  stamp="$(date '+%Y%m%d-%H%M%S')"
  AIDNS_LOG_FILE="$dir/aidns-${action,,}-$stamp.log"
  # retention
  local files
  mapfile -t files < <(ls -1t "$dir"/aidns-*.log 2>/dev/null || true)
  if [[ ${#files[@]} -gt $AIDNS_LOG_RETENTION ]]; then
    local i
    for ((i = AIDNS_LOG_RETENTION; i < ${#files[@]}; i++)); do
      rm -f "${files[$i]}" || true
    done
  fi
  aidns_log_record "INFO" "AI-DNS $AIDNS_MODULE_VERSION action=$action dry_run=$AIDNS_DRY_RUN trace=$AIDNS_TRACE"
}

aidns_system_change() {
  local description="$1"
  shift
  if [[ "$AIDNS_DRY_RUN" -eq 1 ]]; then
    aidns_note "Common.DryRunChange" "$description"
    return 0
  fi
  aidns_trace "change: $description"
  "$@"
}

aidns_need_cmd() {
  local c
  for c in "$@"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      aidns_fail "Error.MissingCommand" "$c"
      return 1
    fi
  done
}

aidns_wait_exit() {
  local code="$1"
  if [[ "$AIDNS_NO_WAIT" -eq 1 ]]; then
    return
  fi
  local secs="${AIDNS_SETTING_WAIT_SECONDS:-20}"
  if [[ "$code" -ne 0 ]]; then
    secs=$((secs > 30 ? secs : 30))
  fi
  if [[ "$secs" -le 0 ]]; then
    return
  fi
  printf "\n"
  aidns_note "Common.WaitHint" "$secs"
  # shellcheck disable=SC2034
  read -r -t "$secs" -n 1 _ || true
}

# JSON helpers via python3 (universally available on modern Linux)
aidns_json_get() {
  local file="$1"
  local expr="$2"
  local default="${3:-}"
  python3 - "$file" "$expr" "$default" <<'PY'
import json, sys
path, expr, default = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print(default)
    raise SystemExit(0)
cur = data
for part in expr.split("."):
    if part == "":
        continue
    if isinstance(cur, dict) and part in cur:
        cur = cur[part]
    else:
        print(default)
        raise SystemExit(0)
if isinstance(cur, bool):
    print("true" if cur else "false")
elif cur is None:
    print(default)
elif isinstance(cur, (list, dict)):
    print(json.dumps(cur, ensure_ascii=False))
else:
    print(cur)
PY
}

aidns_json_write() {
  local file="$1"
  local json="$2"
  if [[ "$AIDNS_DRY_RUN" -eq 1 ]]; then
    aidns_note "Common.DryRunChange" "Write $file"
    return 0
  fi
  local dir
  dir="$(dirname "$file")"
  mkdir -p "$dir"
  local tmp
  tmp="$(mktemp)"
  printf "%s\n" "$json" >"$tmp"
  python3 -c "import json,sys; json.load(open(sys.argv[1],encoding='utf-8'))" "$tmp"
  mv -f "$tmp" "$file"
}

aidns_is_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local o IFS=.
  # shellcheck disable=SC2086
  set -- $ip
  for o in "$@"; do
    [[ "$o" -ge 0 && "$o" -le 255 ]] || return 1
  done
  return 0
}

aidns_is_public_ipv4() {
  local ip="$1"
  aidns_is_ipv4 "$ip" || return 1
  local a b
  IFS=. read -r a b _ _ <<<"$ip"
  [[ "$a" -eq 10 ]] && return 1
  [[ "$a" -eq 127 ]] && return 1
  [[ "$a" -eq 0 ]] && return 1
  [[ "$a" -eq 169 && "$b" -eq 254 ]] && return 1
  [[ "$a" -eq 172 && "$b" -ge 16 && "$b" -le 31 ]] && return 1
  [[ "$a" -eq 192 && "$b" -eq 168 ]] && return 1
  [[ "$a" -ge 224 ]] && return 1
  return 0
}

aidns_median() {
  local -a vals=("$@")
  local n=${#vals[@]}
  if [[ "$n" -eq 0 ]]; then
    echo ""
    return
  fi
  local sorted
  mapfile -t sorted < <(printf "%s\n" "${vals[@]}" | sort -n)
  if (( n % 2 == 1 )); then
    echo "${sorted[$((n / 2))]}"
  else
    local a="${sorted[$((n / 2 - 1))]}"
    local b="${sorted[$((n / 2))]}"
    echo $(( (a + b) / 2 ))
  fi
}
