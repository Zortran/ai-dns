# Provider catalog: bundled providers.json + remote feeds with cache.

# Global arrays filled by aidns_get_provider_catalog
AIDNS_PROVIDER_IDS=()
AIDNS_PROVIDER_NAMES=()
AIDNS_PROVIDER_IPV4=()   # space-separated per provider index
AIDNS_PROVIDER_HOSTS=()  # space-separated
AIDNS_CANDIDATE_IPS=()
AIDNS_CANDIDATE_PROVIDER_IDX=()
AIDNS_RETIRED_IPS=()

aidns_provider_index_by_id() {
  local id="$1" i
  for i in "${!AIDNS_PROVIDER_IDS[@]}"; do
    if [[ "${AIDNS_PROVIDER_IDS[$i]}" == "$id" ]]; then
      echo "$i"
      return 0
    fi
  done
  return 1
}

aidns_provider_name_for_ip() {
  local ip="$1" i ips
  for i in "${!AIDNS_CANDIDATE_IPS[@]}"; do
    if [[ "${AIDNS_CANDIDATE_IPS[$i]}" == "$ip" ]]; then
      local idx="${AIDNS_CANDIDATE_PROVIDER_IDX[$i]}"
      echo "${AIDNS_PROVIDER_NAMES[$idx]}"
      return
    fi
  done
  echo "unknown"
}

aidns_provider_id_for_ip() {
  local ip="$1" i
  for i in "${!AIDNS_CANDIDATE_IPS[@]}"; do
    if [[ "${AIDNS_CANDIDATE_IPS[$i]}" == "$ip" ]]; then
      local idx="${AIDNS_CANDIDATE_PROVIDER_IDX[$i]}"
      echo "${AIDNS_PROVIDER_IDS[$idx]}"
      return
    fi
  done
  echo ""
}

aidns_download_feed() {
  local dest="$1"
  shift
  local url
  for url in "$@"; do
    if curl -fsSL --connect-timeout "$AIDNS_FEED_TIMEOUT" --max-time "$AIDNS_FEED_TIMEOUT" \
      -o "$dest" "$url" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

aidns_feed_cache_path() {
  echo "$AIDNS_CACHE/feed-$1.txt"
}

# Load providers from JSON text into python merge pipeline.
# Outputs lines: id|name|ip1,ip2|host1,host2
aidns_parse_aidns_json() {
  local file="$1"
  local source="$2"
  python3 - "$file" "$source" <<'PY'
import json, sys, re
path, source = sys.argv[1], sys.argv[2]
ipv4 = re.compile(r"^(?:\d{1,3}\.){3}\d{1,3}$")
host_re = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$", re.I)
with open(path, encoding="utf-8") as f:
    doc = json.load(f)
ver = doc.get("schemaVersion")
if ver != 1:
    raise SystemExit(f"bad schema {ver}")
count = 0
for entry in doc.get("providers") or []:
    if count >= 512:
        break
    pid = str(entry.get("id") or "")
    if not re.match(r"^[a-z0-9][a-z0-9-]{0,31}$", pid):
        continue
    name = str(entry.get("name") or pid)[:40]
    ips = []
    for ip in entry.get("ipv4") or []:
        s = str(ip).strip()
        if ipv4.match(s) and s not in ips:
            # public-ish filter: skip obvious private
            a, b, *_ = map(int, s.split("."))
            if a in (0, 10, 127) or a >= 224: continue
            if a == 192 and b == 168: continue
            if a == 172 and 16 <= b <= 31: continue
            if a == 169 and b == 254: continue
            ips.append(s)
            if len(ips) >= 32: break
    hosts = []
    for h in entry.get("hosts") or []:
        s = str(h).strip().lower().rstrip(".")
        if host_re.match(s) and s not in hosts:
            hosts.append(s)
            if len(hosts) >= 32: break
    for tmpl in entry.get("doh") or []:
        m = re.match(r"^https://([^/\s:?#]+)/", str(tmpl), re.I)
        if m:
            s = m.group(1).lower()
            if host_re.match(s) and s not in hosts:
                hosts.append(s)
    if not ips and not hosts:
        continue
    print(f"{pid}|{name}|{','.join(ips)}|{','.join(hosts)}|{source}")
    count += 1
for ip in doc.get("retiredIpv4") or []:
    s = str(ip).strip()
    if ipv4.match(s):
        print(f"__retired__|{s}|||")
PY
}

aidns_parse_dnsswitch() {
  local file="$1"
  python3 - "$file" <<'PY'
import re, sys
path = sys.argv[1]
ipv4 = re.compile(r"^(?:\d{1,3}\.){3}\d{1,3}$")
count = 0
with open(path, encoding="utf-8", errors="replace") as f:
    for line in f:
        if count >= 512:
            break
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = [p.strip() for p in line.split("|")]
        if len(parts) < 4:
            continue
        slug = re.sub(r"[^a-z0-9-]", "", parts[0].lower())
        if not slug:
            continue
        pid = ("dnsswitch-" + slug)[:32].rstrip("-")
        name = (parts[1] or pid)[:40]
        ips = []
        for tok in re.split(r"[,;\s]+", parts[3]):
            if ipv4.match(tok) and tok not in ips:
                ips.append(tok)
                if len(ips) >= 32:
                    break
        hosts = []
        if not ips:
            continue
        print(f"{pid}|{name}|{','.join(ips)}|{','.join(hosts)}|dnsswitch")
        count += 1
PY
}

aidns_get_provider_catalog() {
  local refresh="${1:-0}"
  local offline="${2:-0}"

  aidns_ensure_writable_cache
  local -a rows=()
  local retired=()

  # Bundled
  if [[ -f "$AIDNS_CATALOG" ]]; then
    while IFS= read -r line; do
      if [[ "$line" == __retired__* ]]; then
        retired+=("$(echo "$line" | cut -d'|' -f2)")
      else
        rows+=("$line")
      fi
    done < <(aidns_parse_aidns_json "$AIDNS_CATALOG" "bundled")
  fi

  # Feeds
  local feed
  for feed in "${AIDNS_FEEDS[@]}"; do
    IFS='|' read -r fid format url1 url2 <<<"$feed"
    local cache
    cache="$(aidns_feed_cache_path "$fid")"
    local origin="Unavailable"
    local parsed_count=0

    if [[ "$offline" -eq 0 ]]; then
      local need_download=1
      if [[ "$refresh" -eq 0 && -f "$cache" ]]; then
        local age
        age=$(( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) ))
        if [[ "$age" -lt "$AIDNS_FEED_TTL_SECONDS" ]]; then
          need_download=0
          origin="Cache"
        fi
      fi
      if [[ "$need_download" -eq 1 ]]; then
        local tmp
        tmp="$(mktemp)"
        if aidns_download_feed "$tmp" "$url1" "$url2"; then
          mv -f "$tmp" "$cache"
          origin="Remote"
        else
          rm -f "$tmp"
          if [[ -f "$cache" ]]; then
            origin="StaleCache"
          fi
        fi
      fi
    else
      if [[ -f "$cache" ]]; then
        origin="Cache"
      fi
    fi

    if [[ -f "$cache" && "$origin" != "Unavailable" ]]; then
      local -a feed_rows=()
      if [[ "$format" == "AiDnsJson" ]]; then
        mapfile -t feed_rows < <(aidns_parse_aidns_json "$cache" "$fid" 2>/dev/null || true)
      else
        mapfile -t feed_rows < <(aidns_parse_dnsswitch "$cache" 2>/dev/null || true)
      fi
      local line
      for line in "${feed_rows[@]}"; do
        if [[ "$line" == __retired__* ]]; then
          retired+=("$(echo "$line" | cut -d'|' -f2)")
        else
          rows+=("$line")
          parsed_count=$((parsed_count + 1))
        fi
      done
      case "$origin" in
        Remote) aidns_ok "Catalog.FeedRemote" "$fid" "$parsed_count" ;;
        Cache) aidns_ok "Catalog.FeedCache" "$fid" "$parsed_count" ;;
        StaleCache) aidns_warn "Catalog.FeedStale" "$fid" "$parsed_count" ;;
      esac
    else
      aidns_warn "Catalog.FeedUnavailable" "$fid"
    fi
  done

  # Custom resolvers as a synthetic provider
  if [[ ${#AIDNS_CUSTOM_RESOLVERS[@]} -gt 0 ]]; then
    local ips
    ips="$(IFS=','; echo "${AIDNS_CUSTOM_RESOLVERS[*]}")"
    rows+=("custom|Custom|$ips||settings")
  fi

  # Merge by id / shared IP / host
  AIDNS_PROVIDER_IDS=()
  AIDNS_PROVIDER_NAMES=()
  AIDNS_PROVIDER_IPV4=()
  AIDNS_PROVIDER_HOSTS=()
  AIDNS_RETIRED_IPS=("${retired[@]}")

  python3 - "${rows[@]}" <<'PY' >"$AIDNS_CACHE/_merged_providers.txt"
import sys
rows = sys.argv[1:]
merged = []  # list of dicts

def find_target(pid, ips, hosts):
    for m in merged:
        if m["id"] == pid:
            return m
        if any(ip in m["ips"] for ip in ips):
            return m
        if any(h in m["hosts"] for h in hosts):
            return m
    return None

for row in rows:
    parts = row.split("|")
    if len(parts) < 5:
        continue
    pid, name, ips_s, hosts_s, source = parts[0], parts[1], parts[2], parts[3], parts[4]
    ips = [x for x in ips_s.split(",") if x]
    hosts = [x for x in hosts_s.split(",") if x]
    t = find_target(pid, ips, hosts)
    if t is None:
        if len(merged) >= 512:
            continue
        merged.append({"id": pid, "name": name, "ips": list(ips), "hosts": list(hosts), "source": source})
        continue
    for ip in ips:
        if ip not in t["ips"] and len(t["ips"]) < 32:
            t["ips"].append(ip)
    for h in hosts:
        if h not in t["hosts"] and len(t["hosts"]) < 32:
            t["hosts"].append(h)

for m in merged:
    print(f"{m['id']}|{m['name']}|{','.join(m['ips'])}|{','.join(m['hosts'])}")
PY

  while IFS='|' read -r pid name ips hosts; do
    [[ -z "$pid" ]] && continue
    AIDNS_PROVIDER_IDS+=("$pid")
    AIDNS_PROVIDER_NAMES+=("$name")
    AIDNS_PROVIDER_IPV4+=("${ips//,/ }")
    AIDNS_PROVIDER_HOSTS+=("${hosts//,/ }")
  done <"$AIDNS_CACHE/_merged_providers.txt"

  # Build candidate IP list with filters
  AIDNS_CANDIDATE_IPS=()
  AIDNS_CANDIDATE_PROVIDER_IDX=()
  local i ip blocked_prov=0 excluded=0
  local -A seen_ip=()

  for i in "${!AIDNS_PROVIDER_IDS[@]}"; do
    local pid="${AIDNS_PROVIDER_IDS[$i]}"
    local skip=0
    local b
    for b in "${AIDNS_BLOCKED_PROVIDERS[@]:-}"; do
      if [[ "$b" == "$pid" ]]; then skip=1; break; fi
    done
    if [[ "$skip" -eq 1 ]]; then
      blocked_prov=$((blocked_prov + 1))
      continue
    fi
    for ip in ${AIDNS_PROVIDER_IPV4[$i]}; do
      local blocked=0
      for b in "${AIDNS_BLOCKED_ADDRESSES[@]:-}"; do
        if [[ "$b" == "$ip" ]]; then blocked=1; break; fi
      done
      if [[ "$blocked" -eq 1 ]]; then
        excluded=$((excluded + 1))
        continue
      fi
      if [[ -n "${seen_ip[$ip]:-}" ]]; then
        continue
      fi
      if [[ ${#AIDNS_CANDIDATE_IPS[@]} -ge $AIDNS_MAX_CANDIDATES ]]; then
        break 2
      fi
      if ! aidns_is_public_ipv4 "$ip"; then
        continue
      fi
      seen_ip[$ip]=1
      AIDNS_CANDIDATE_IPS+=("$ip")
      AIDNS_CANDIDATE_PROVIDER_IDX+=("$i")
    done
  done

  local addr_count=${#AIDNS_CANDIDATE_IPS[@]}
  aidns_ok "Catalog.Summary" "${#AIDNS_PROVIDER_IDS[@]}" "$addr_count"
  if [[ "$blocked_prov" -gt 0 || "$excluded" -gt 0 ]]; then
    aidns_note "Reference.Excluded" "$blocked_prov" "$excluded"
  fi
}

# Resolve provider host names through reference DNS; append discovered public IPs.
aidns_discover_provider_ips() {
  local discovered=0
  local i host ip
  local -A seen=()
  local x
  for x in "${AIDNS_CANDIDATE_IPS[@]}"; do seen["$x"]=1; done

  for i in "${!AIDNS_PROVIDER_IDS[@]}"; do
    local pid="${AIDNS_PROVIDER_IDS[$i]}"
    local skip=0 b
    for b in "${AIDNS_BLOCKED_PROVIDERS[@]:-}"; do
      [[ "$b" == "$pid" ]] && skip=1 && break
    done
    [[ "$skip" -eq 1 ]] && continue

    for host in ${AIDNS_PROVIDER_HOSTS[$i]}; do
      local ref
      for ref in "${AIDNS_REFERENCE_RESOLVERS[@]:0:2}"; do
        while IFS= read -r ip; do
          [[ -z "$ip" ]] && continue
          aidns_is_public_ipv4 "$ip" || continue
          local blocked=0
          for b in "${AIDNS_BLOCKED_ADDRESSES[@]:-}"; do
            [[ "$b" == "$ip" ]] && blocked=1 && break
          done
          [[ "$blocked" -eq 1 ]] && continue
          if [[ -z "${seen[$ip]:-}" && ${#AIDNS_CANDIDATE_IPS[@]} -lt $AIDNS_MAX_CANDIDATES ]]; then
            seen[$ip]=1
            AIDNS_CANDIDATE_IPS+=("$ip")
            AIDNS_CANDIDATE_PROVIDER_IDX+=("$i")
            # also extend provider ipv4 list
            AIDNS_PROVIDER_IPV4[$i]="${AIDNS_PROVIDER_IPV4[$i]} $ip"
            discovered=$((discovered + 1))
          fi
        done < <(dig @"$ref" +time="$AIDNS_DNS_TIMEOUT" +tries=1 +short A "$host" 2>/dev/null | grep -E '^[0-9.]+$' || true)
      done
    done
  done
  echo "$discovered"
}
