# Static configuration: services, feeds, timing (Linux port of Config.ps1).

AIDNS_REQUIRED_WEIGHT=1000
AIDNS_CUSTOM_SERVICE_LIMIT=16
AIDNS_MAX_CANDIDATES=1024
AIDNS_PROBE_DOMAIN="ya.ru"

AIDNS_DNS_TIMEOUT=1
AIDNS_DNS_TRIES=2
AIDNS_CONNECT_TIMEOUT=3
AIDNS_IO_TIMEOUT=4
AIDNS_HTTPS_PARALLEL=32
AIDNS_LATENCY_SAMPLES=3
AIDNS_FEED_TTL_SECONDS=$((6 * 3600))
AIDNS_FEED_TIMEOUT=6

AIDNS_REFERENCE_RESOLVERS=(77.88.8.8 77.88.8.1 8.8.8.8 1.1.1.1)
AIDNS_BLOCKED_REGIONS=(RU BY CN HK MO IR KP CU SY T1 XX)
AIDNS_GOOGLE_PREFIXES=(142.250 142.251 172.217 172.253 216.58 216.239 74.125 173.194 64.233 108.177 209.85)

# Service table rows: id|mode|name|domain|weight|group|kind|region_from|claude_code|checks
# checks: path[,maxbytes][+header=...]; multiple checks separated by ;;
AIDNS_BUILTIN_SERVICES=(
  "chatgpt|Required|ChatGPT|chatgpt.com|100|Web|Cloudflare||0|/cdn-cgi/trace,8192;;/,65536"
  "claude|Required|Claude|claude.ai|100|Web|Cloudflare||0|/cdn-cgi/trace,8192;;/,65536"
  "gemini|Preferred|Gemini|gemini.google.com|100|Web|GoogleWeb|gemini-api|0|/,65536"
  "openai-api|Preferred|OpenAI API|api.openai.com|30|Api|OpenAiApi||0|/v1/models,8192"
  "anthropic-api|Preferred|Anthropic API|api.anthropic.com|60|Api|AnthropicApi||1|/v1/models,8192,anthropic-version: 2023-06-01,x-api-key: sk-ant-aidns-geo-probe"
  "gemini-api|Preferred|Gemini API|generativelanguage.googleapis.com|30|Api|GoogleApi||0|/v1beta/models?key=AIzaSyAIDNS-geo-probe-not-a-real-key00,8192"
  "code-login|Preferred|platform.claude.com|platform.claude.com|40|Support|Generic||1|/cdn-cgi/trace,8192;;/,65536"
  "code-site|Preferred|claude.com|claude.com|10|Support|Generic||1|/cdn-cgi/trace,8192;;/,65536"
  "code-updates|Preferred|downloads.claude.ai|downloads.claude.ai|5|Support|Generic||1|/cdn-cgi/trace,8192"
)

# Active service list for this run (array of id|mode|... rows)
AIDNS_SERVICES=()

AIDNS_FEEDS=(
  "aidns|AiDnsJson|https://raw.githubusercontent.com/Mahiron-hq/ai-dns/main/src/providers.json|https://cdn.jsdelivr.net/gh/Mahiron-hq/ai-dns@main/src/providers.json"
  "dnsswitch|DnsSwitchPresets|https://raw.githubusercontent.com/WhIteGh0s1/DnsSwitch/main/presets.txt|https://cdn.jsdelivr.net/gh/WhIteGh0s1/DnsSwitch@main/presets.txt"
)

aidns_service_field() {
  local row="$1"
  local index="$2"
  local -a parts
  IFS='|' read -ra parts <<<"$row"
  printf '%s\n' "${parts[$index]:-}"
}

aidns_service_by_id() {
  local id="$1"
  local row
  for row in "${AIDNS_SERVICES[@]}"; do
    if [[ "$(aidns_service_field "$row" 0)" == "$id" ]]; then
      echo "$row"
      return 0
    fi
  done
  return 1
}

aidns_reset_services_from_builtin() {
  AIDNS_SERVICES=("${AIDNS_BUILTIN_SERVICES[@]}")
}

aidns_gating_ids() {
  local row id mode group
  local -a gating=()
  local -a active=()
  for row in "${AIDNS_SERVICES[@]}"; do
    mode="$(aidns_service_field "$row" 1)"
    [[ "$mode" == "Off" ]] && continue
    active+=("$row")
    group="$(aidns_service_field "$row" 5)"
    if [[ "$group" == "Web" || "$group" == "Custom" ]]; then
      gating+=("$(aidns_service_field "$row" 0)")
    fi
  done
  if [[ ${#gating[@]} -gt 0 ]]; then
    printf "%s\n" "${gating[@]}"
  else
    for row in "${active[@]}"; do
      echo "$(aidns_service_field "$row" 0)"
    done
  fi
}

aidns_is_blocked_region() {
  local r="$1"
  local x
  for x in "${AIDNS_BLOCKED_REGIONS[@]}"; do
    [[ "$x" == "$r" ]] && return 0
  done
  return 1
}

aidns_is_google_prefix() {
  local net16="$1"
  local x
  for x in "${AIDNS_GOOGLE_PREFIXES[@]}"; do
    [[ "$x" == "$net16" ]] && return 0
  done
  return 1
}

aidns_net16() {
  local ip="$1" a b
  IFS=. read -r a b _ _ <<<"$ip"
  echo "$a.$b"
}
