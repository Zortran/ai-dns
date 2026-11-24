#!/usr/bin/env bash
# AI-DNS Linux port: find a working smart DNS and apply it via systemd-resolved.
set -euo pipefail

AIDNS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$AIDNS_ROOT/lib/common.sh"
# shellcheck source=lib/config.sh
source "$AIDNS_ROOT/lib/config.sh"
# shellcheck source=lib/settings.sh
source "$AIDNS_ROOT/lib/settings.sh"
# shellcheck source=lib/resolved.sh
source "$AIDNS_ROOT/lib/resolved.sh"
# shellcheck source=lib/backup.sh
source "$AIDNS_ROOT/lib/backup.sh"
# shellcheck source=lib/state.sh
source "$AIDNS_ROOT/lib/state.sh"
# shellcheck source=lib/hosts.sh
source "$AIDNS_ROOT/lib/hosts.sh"
# shellcheck source=lib/providers.sh
source "$AIDNS_ROOT/lib/providers.sh"
# shellcheck source=lib/probe.sh
source "$AIDNS_ROOT/lib/probe.sh"
# shellcheck source=lib/evaluate.sh
source "$AIDNS_ROOT/lib/evaluate.sh"
# shellcheck source=lib/enable.sh
source "$AIDNS_ROOT/lib/enable.sh"
# shellcheck source=lib/disable.sh
source "$AIDNS_ROOT/lib/disable.sh"
# shellcheck source=lib/status.sh
source "$AIDNS_ROOT/lib/status.sh"
# shellcheck source=lib/update.sh
source "$AIDNS_ROOT/lib/update.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") --action Enable|Disable|Update|Status [options]

Options:
  --test-only          Enable: rank resolvers, change nothing
  --dry-run            Log changes instead of applying them
  --trace              Verbose probe/change logging
  --offline            Do not download provider feeds
  --full               Disable/Update: aggressive cleanup
  --enable-ipv6        Disable/Update: re-enable IPv6 via sysctl
  --language Auto|en|ru
  --log-directory PATH
  --no-wait            Do not pause before exit
  -h, --help           Show this help
EOF
}

AIDNS_ACTION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --action) AIDNS_ACTION="${2:-}"; shift 2 ;;
    --test-only) AIDNS_TEST_ONLY=1; shift ;;
    --dry-run) AIDNS_DRY_RUN=1; shift ;;
    --trace) AIDNS_TRACE=1; shift ;;
    --offline) AIDNS_OFFLINE=1; shift ;;
    --full) AIDNS_FULL=1; shift ;;
    --enable-ipv6) AIDNS_ENABLE_IPV6=1; shift ;;
    --language) AIDNS_LANGUAGE="${2:-Auto}"; shift 2 ;;
    --log-directory) AIDNS_LOG_DIRECTORY="${2:-}"; shift 2 ;;
    --no-wait) AIDNS_NO_WAIT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    Enable|Disable|Update|Status)
      AIDNS_ACTION="$1"; shift ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$AIDNS_ACTION" ]]; then
  usage >&2
  exit 1
fi

case "$AIDNS_ACTION" in
  Enable|Disable|Update|Status) ;;
  *) echo "Invalid action: $AIDNS_ACTION" >&2; exit 1 ;;
esac

aidns_load_settings
aidns_merge_setting_flags "$AIDNS_ACTION"

if [[ -n "$AIDNS_SETTING_LOG_DIRECTORY" && -z "$AIDNS_LOG_DIRECTORY" ]]; then
  AIDNS_LOG_DIRECTORY="$AIDNS_SETTING_LOG_DIRECTORY"
fi
if [[ -n "$AIDNS_LOG_DIRECTORY" && "$AIDNS_LOG_DIRECTORY" != /* ]]; then
  AIDNS_LOG_DIRECTORY="$AIDNS_ROOT/$AIDNS_LOG_DIRECTORY"
fi

AIDNS_LANG="$(aidns_resolve_language "$AIDNS_LANGUAGE")"
aidns_load_strings "$AIDNS_LANG"

AIDNS_STARTED_AT="$(date +%s)"
aidns_init_log "$AIDNS_ACTION"

printf "%s\n" "AI-DNS $AIDNS_MODULE_VERSION · $(aidns_text "Banner.$AIDNS_ACTION")"
aidns_log_record "INFO" "action=$AIDNS_ACTION lang=$AIDNS_LANG"

# Status and Enable --test-only never change the system, so root is not required.
if [[ "$AIDNS_ACTION" != "Status" && ! ( "$AIDNS_ACTION" == "Enable" && "$AIDNS_TEST_ONLY" -eq 1 ) ]]; then
  if ! aidns_is_root; then
    aidns_fail "Error.NotElevated"
    aidns_wait_exit 1
    exit 1
  fi
fi

if [[ "$AIDNS_TEST_ONLY" -eq 1 && "$AIDNS_ACTION" != "Enable" ]]; then
  aidns_fail "Error.OptionAction" "--test-only" "Enable"
  aidns_wait_exit 1
  exit 1
fi

exit_code=1
set +e
case "$AIDNS_ACTION" in
  Enable)  aidns_enable 0; exit_code=$? ;;
  Disable) aidns_disable 0; exit_code=$? ;;
  Update)  aidns_update; exit_code=$? ;;
  Status)  aidns_status; exit_code=$? ;;
esac
set -e

aidns_wait_exit "$exit_code"
exit "$exit_code"
