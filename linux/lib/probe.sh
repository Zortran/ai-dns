# DNS (dig) and HTTPS (curl --resolve) probing.

AIDNS_PROBE_DIR=""

declare -A AIDNS_DNS_RESULT=()
declare -A AIDNS_HTTPS_RESULT=()
declare -A AIDNS_REFERENCE=()
declare -A AIDNS_CAND_ALIVE=()
declare -A AIDNS_CAND_DNS_MS=()
declare -A AIDNS_CAND_TLS_MS=()
declare -A AIDNS_CAND_SCORE=()
declare -A AIDNS_CAND_WEB=()
declare -A AIDNS_CAND_API=()
declare -A AIDNS_CAND_MASK=()
declare -A AIDNS_VERDICT=()

aidns_probe_init() {
  AIDNS_PROBE_DIR="$(mktemp -d /tmp/aidns-probe.XXXXXX)"
  AIDNS_DNS_RESULT=()
  AIDNS_HTTPS_RESULT=()
  AIDNS_REFERENCE=()
  AIDNS_CAND_ALIVE=()
  AIDNS_CAND_DNS_MS=()
  AIDNS_CAND_TLS_MS=()
  AIDNS_CAND_SCORE=()
  AIDNS_CAND_WEB=()
  AIDNS_CAND_API=()
  AIDNS_CAND_MASK=()
  AIDNS_VERDICT=()
}

aidns_probe_cleanup() {
  if [[ -n "${AIDNS_PROBE_DIR:-}" && -d "${AIDNS_PROBE_DIR:-}" ]]; then
    rm -rf "$AIDNS_PROBE_DIR"
  fi
}

aidns_check_key() {
  echo "$1|$2|$3"
}

aidns_dig_batch_file() {
  local list_file="$1"
  local parallel="${2:-$AIDNS_HTTPS_PARALLEL}"
  xargs -P "$parallel" -a "$list_file" -n 4 bash -c '
    server="$1"; name="$2"; tag="$3"; out="$4"
    start=$(date +%s%3N 2>/dev/null || echo 0)
    raw=$(dig @"$server" +time='"$AIDNS_DNS_TIMEOUT"' +tries='"$AIDNS_DNS_TRIES"' +short A "$name" 2>/dev/null || true)
    end=$(date +%s%3N 2>/dev/null || echo 0)
    rtt=$((end - start))
    answered=0; ok=0; err=EmptyAnswer; ips=""
    while IFS= read -r line; do
      case "$line" in
        [0-9]*.[0-9]*.[0-9]*.[0-9]*) ;;
        *) continue ;;
      esac
      answered=1
      case "$line" in
        0.0.0.0|127.*) err=Blackholed; continue ;;
      esac
      if [ -z "$ips" ]; then ips="$line"; else ips="$ips,$line"; fi
    done <<EOF
$raw
EOF
    if [ -n "$ips" ]; then ok=1; err=None
    elif [ "$answered" -eq 1 ] && [ "$err" = "EmptyAnswer" ]; then err=Blackholed
    elif [ "$answered" -eq 0 ]; then err=Timeout
    fi
    [ -z "$ips" ] && ips="-"
    printf "%s %s %s %s %s %s\n" "$tag" "$answered" "$ok" "$err" "$ips" "$rtt" >"$out"
  ' _
}

aidns_get_reference_answers() {
  local -a domains=("$@")
  local d r
  for d in "${domains[@]}"; do
    local -a addrs=()
    for r in "${AIDNS_REFERENCE_RESOLVERS[@]}"; do
      while IFS= read -r ip; do
        [[ "$ip" =~ ^[0-9.]+$ ]] || continue
        [[ "$ip" == "0.0.0.0" || "$ip" == 127.* ]] && continue
        addrs+=("$ip")
      done < <(dig @"$r" +time="$AIDNS_DNS_TIMEOUT" +tries=1 +short A "$d" 2>/dev/null || true)
    done
    local uniq
    uniq="$(printf "%s\n" "${addrs[@]:-}" | awk 'NF' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    AIDNS_REFERENCE["$d"]="$uniq"
    aidns_trace "reference $d -> $uniq"
  done
}

aidns_probe_candidates_dns() {
  local dir="$AIDNS_PROBE_DIR/dns"
  mkdir -p "$dir"
  local list="$dir/jobs.txt"
  : >"$list"

  local -a active_domains=()
  local -a active_ids=()
  local row
  for row in "${AIDNS_SERVICES[@]}"; do
    local mode id domain
    mode="$(aidns_service_field "$row" 1)"
    [[ "$mode" == "Off" ]] && continue
    id="$(aidns_service_field "$row" 0)"
    domain="$(aidns_service_field "$row" 3)"
    active_ids+=("$id")
    active_domains+=("$domain")
  done
  for row in "${AIDNS_SERVICES[@]}"; do
    local mode region
    mode="$(aidns_service_field "$row" 1)"
    region="$(aidns_service_field "$row" 7)"
    [[ "$mode" == "Off" || -z "$region" ]] && continue
    local extra
    if extra="$(aidns_service_by_id "$region")"; then
      local eid edomain found=0 a
      eid="$(aidns_service_field "$extra" 0)"
      edomain="$(aidns_service_field "$extra" 3)"
      for a in "${active_ids[@]:-}"; do [[ "$a" == "$eid" ]] && found=1 && break; done
      if [[ "$found" -eq 0 ]]; then
        active_ids+=("$eid")
        active_domains+=("$edomain")
      fi
    fi
  done

  local ip j=0 n idx
  for ip in "${AIDNS_CANDIDATE_IPS[@]}"; do
    for ((n = 0; n < AIDNS_LATENCY_SAMPLES; n++)); do
      printf '%s %s %s %s\n' "$ip" "$AIDNS_PROBE_DOMAIN" "latency|$ip|$n" "$dir/L-$j.txt" >>"$list"
      j=$((j + 1))
    done
    for idx in "${!active_ids[@]}"; do
      printf '%s %s %s %s\n' "$ip" "${active_domains[$idx]}" "svc|${active_ids[$idx]}|$ip" "$dir/S-$j.txt" >>"$list"
      j=$((j + 1))
    done
  done

  if [[ -s "$list" ]]; then
    aidns_dig_batch_file "$list" "$AIDNS_HTTPS_PARALLEL"
  fi

  declare -A lat_samples=()
  for ip in "${AIDNS_CANDIDATE_IPS[@]}"; do
    AIDNS_CAND_ALIVE["$ip"]=0
    lat_samples["$ip"]=""
  done

  local f tag answered ok err ips rtt
  for f in "$dir"/L-*.txt "$dir"/S-*.txt; do
    [[ -f "$f" ]] || continue
    read -r tag answered ok err ips rtt <"$f" || true
    local kind="${tag%%|*}"
    local rest="${tag#*|}"
    [[ "$ips" == "-" ]] && ips=""
    if [[ "$kind" == "latency" ]]; then
      local cip="${rest%%|*}"
      [[ "$answered" == "1" ]] && AIDNS_CAND_ALIVE["$cip"]=1
      [[ "$ok" == "1" && -n "$rtt" ]] && lat_samples["$cip"]="${lat_samples[$cip]} $rtt"
    elif [[ "$kind" == "svc" ]]; then
      local sid="${rest%%|*}"
      local cip="${rest#*|}"
      [[ "$answered" == "1" ]] && AIDNS_CAND_ALIVE["$cip"]=1
      AIDNS_DNS_RESULT["$cip|$sid"]="$ok|$err|$ips|$rtt"
      [[ "$ok" == "1" && -n "$rtt" ]] && lat_samples["$cip"]="${lat_samples[$cip]} $rtt"
      aidns_trace "dns $cip $sid -> $ips ($err ${rtt}ms)"
    fi
  done

  for ip in "${AIDNS_CANDIDATE_IPS[@]}"; do
    # shellcheck disable=SC2086
    AIDNS_CAND_DNS_MS["$ip"]="$(aidns_median ${lat_samples[$ip]:-})"
  done
}

aidns_https_probe_to_file() {
  local address="$1" domain="$2" path="$3" max_bytes="$4" out="$5"
  shift 5 || true
  local -a header_args=()
  local h
  for h in "$@"; do
    [[ -n "$h" ]] && header_args+=(-H "$h")
  done
  local body hdr errf
  body="$(mktemp)"; hdr="$(mktemp)"; errf="$(mktemp)"
  local start end code tcp=0 tls=0 stalled=0
  start=$(date +%s%3N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1000))')
  set +e
  code="$(curl -sS -o "$body" -D "$hdr" \
    --connect-timeout "$AIDNS_CONNECT_TIMEOUT" \
    --max-time "$AIDNS_IO_TIMEOUT" \
    --max-filesize "$max_bytes" \
    --resolve "${domain}:443:${address}" \
    "${header_args[@]}" \
    -w "%{http_code}" \
    "https://${domain}${path}" 2>"$errf")"
  set -e
  end=$(date +%s%3N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1000))')
  local tls_ms=$((end - start))
  local errmsg
  errmsg="$(cat "$errf" 2>/dev/null || true)"
  if [[ -z "$code" || "$code" == "000" ]]; then
    code=0
    [[ -s "$body" ]] && stalled=1
    if echo "$errmsg" | grep -qiE 'ssl|certificate|tls'; then tcp=1; tls=0
    else tcp=0; tls=0
    fi
  else
    tcp=1; tls=1
  fi
  local head
  head="$( (head -c 4096 "$hdr"; printf '\n'; head -c 2048 "$body") | tr '\n' ' ' | tr '|' '/' | cut -c1-1500 )"
  printf "%s|%s|%s|%s|%s|%s\n" "$tcp" "$tls" "$code" "$tls_ms" "$stalled" "$head" >"$out"
  rm -f "$body" "$hdr" "$errf"
}

aidns_https_batch() {
  local dir="$AIDNS_PROBE_DIR/https"
  mkdir -p "$dir"
  local -A needed=()
  local -a outs=() keys=()
  local running=0 ip

  for ip in "${AIDNS_CANDIDATE_IPS[@]}"; do
    [[ "${AIDNS_CAND_ALIVE[$ip]:-0}" -eq 1 ]] || continue
    local row
    for row in "${AIDNS_SERVICES[@]}"; do
      local id domain checks
      id="$(aidns_service_field "$row" 0)"
      domain="$(aidns_service_field "$row" 3)"
      checks="$(aidns_service_field "$row" 9)"
      local dns="${AIDNS_DNS_RESULT[$ip|$id]:-}"
      [[ -n "$dns" ]] || continue
      local ok err ips rtt
      IFS='|' read -r ok err ips rtt <<<"$dns"
      [[ "$ok" == "1" && -n "$ips" ]] || continue
      local addr="${ips%%,*}"
      local check
      IFS=';' read -ra check_arr <<<"$checks"
      for check in "${check_arr[@]}"; do
        [[ -z "$check" ]] && continue
        local path maxb=8192 rest=""
        path="${check%%,*}"
        rest="${check#"$path"}"; rest="${rest#,}"
        maxb="${rest%%,*}"
        [[ "$maxb" =~ ^[0-9]+$ ]] || maxb=8192
        local headers_raw="${rest#"$maxb"}"; headers_raw="${headers_raw#,}"
        path="${path:-/}"
        local key
        key="$(aidns_check_key "$addr" "$domain" "$path")"
        [[ -n "${needed[$key]:-}" ]] && continue
        needed[$key]=1
        local safe out
        safe="$(printf "%s" "$key" | tr '/|:?&=' '______')"
        out="$dir/$safe.txt"
        keys+=("$key"); outs+=("$out")
        local -a hdrs=()
        if [[ -n "$headers_raw" ]]; then
          while [[ "$headers_raw" =~ ^([^:]+:[^,]+)(,(.*))?$ ]]; do
            hdrs+=("${BASH_REMATCH[1]}")
            headers_raw="${BASH_REMATCH[3]}"
            [[ -z "$headers_raw" ]] && break
          done
        fi
        while [[ "$running" -ge "$AIDNS_HTTPS_PARALLEL" ]]; do
          if wait -n 2>/dev/null; then
            running=$((running > 0 ? running - 1 : 0))
          else
            wait || true
            running=0
            break
          fi
        done
        aidns_https_probe_to_file "$addr" "$domain" "$path" "$maxb" "$out" "${hdrs[@]:-}" &
        running=$((running + 1))
      done
    done
  done
  wait

  local i
  for i in "${!keys[@]}"; do
    [[ -f "${outs[$i]}" ]] || continue
    AIDNS_HTTPS_RESULT["${keys[$i]}"]="$(cat "${outs[$i]}")"
  done
}

aidns_system_resolve() {
  local domain="$1"
  dig +time=2 +tries=2 +short A "$domain" 2>/dev/null \
    | grep -E '^[0-9.]+$' | grep -vE '^(0\.0\.0\.0|127\.)' \
    | head -5 | tr '\n' ',' | sed 's/,$//'
}
