# Verdicts, scoring and plan selection (NoRoutes — Linux has no NRPT).

aidns_format_verdict() {
  local ok="$1" reason="$2"
  shift 2 || true
  if [[ $# -gt 0 ]]; then
    aidns_text "Verdict.$reason" "$@"
  else
    aidns_text "Verdict.$reason"
  fi
}

aidns_get_cloudflare_region() {
  local head="$1"
  if [[ "$head" =~ loc=([A-Z0-9]{2}) ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo ""
  fi
}

aidns_test_cloudflare_challenge() {
  local head="$1"
  [[ "$head" =~ [Cc][Ff]-[Mm]itigated:[[:space:]]*[Cc]hallenge ]]
}

aidns_test_proxied() {
  local address="$1"
  local domain="$2"
  local net16 a b
  IFS=. read -r a b _ _ <<<"$address"
  net16="$a.$b"
  if aidns_is_google_prefix "$net16"; then
    return 1
  fi
  local ref="${AIDNS_REFERENCE[$domain]:-}"
  local rip
  for rip in $ref; do
    local ra rb
    IFS=. read -r ra rb _ _ <<<"$rip"
    if [[ "$net16" == "$ra.$rb" ]]; then
      return 1
    fi
  done
  return 0
}

# Sets AIDNS_VERDICT[ip|sid] = ok|reason|args...
aidns_test_service_access() {
  local ip="$1"
  local row="$2"
  local sid domain kind checks region_from
  sid="$(aidns_service_field "$row" 0)"
  domain="$(aidns_service_field "$row" 3)"
  kind="$(aidns_service_field "$row" 6)"
  region_from="$(aidns_service_field "$row" 7)"
  checks="$(aidns_service_field "$row" 9)"

  local dns="${AIDNS_DNS_RESULT[$ip|$sid]:-}"
  if [[ -z "$dns" ]]; then
    AIDNS_VERDICT["$ip|$sid"]="0|NoData"
    return
  fi
  local dok derr dips drtt
  IFS='|' read -r dok derr dips drtt <<<"$dns"
  if [[ "$dok" != "1" ]]; then
    if [[ "$derr" == "Blackholed" ]]; then
      AIDNS_VERDICT["$ip|$sid"]="0|Blackholed"
    else
      AIDNS_VERDICT["$ip|$sid"]="0|DnsNoAnswer|$(aidns_text "ProbeError.$derr")"
    fi
    return
  fi
  local address="${dips%%,*}"

  local -a results=()
  local check
  IFS=';' read -ra check_arr <<<"$checks"
  for check in "${check_arr[@]}"; do
    [[ -z "$check" ]] && continue
    local path maxb=8192
    IFS=',' read -r path maxb _ <<<"$check"
    path="${path:-/}"
    local key
    key="$(aidns_check_key "$address" "$domain" "$path")"
    local https="${AIDNS_HTTPS_RESULT[$key]:-}"
    if [[ -z "$https" ]]; then
      AIDNS_VERDICT["$ip|$sid"]="0|NotChecked"
      return
    fi
    local tcp tls status tls_ms stalled head
    IFS='|' read -r tcp tls status tls_ms stalled head <<<"$https"
    if [[ "$tcp" != "1" ]]; then
      AIDNS_VERDICT["$ip|$sid"]="0|Unreachable|$address|$(aidns_text ProbeError.Error)"
      return
    fi
    if [[ "$tls" != "1" ]]; then
      if [[ "$head" == *[Cc]ertificate* || "$head" == *[Ss][Ss][Ll]* ]]; then
        AIDNS_VERDICT["$ip|$sid"]="0|TlsForged|cert"
      else
        AIDNS_VERDICT["$ip|$sid"]="0|TlsBlocked|tls"
      fi
      return
    fi
    if [[ "$stalled" == "1" ]]; then
      AIDNS_VERDICT["$ip|$sid"]="0|Stalled|stalled"
      return
    fi
    if [[ "$status" == "0" || -z "$status" ]]; then
      AIDNS_VERDICT["$ip|$sid"]="0|NoHttp|$(aidns_text ProbeError.Error)"
      return
    fi
    results+=("$tcp|$tls|$status|$tls_ms|$stalled|$head")
  done

  local first="${results[0]}"
  local f_tcp f_tls f_status f_tls_ms f_stalled f_head
  IFS='|' read -r f_tcp f_tls f_status f_tls_ms f_stalled f_head <<<"$first"

  case "$kind" in
    Cloudflare)
      local region
      region="$(aidns_get_cloudflare_region "$f_head")"
      if [[ -z "$region" ]]; then
        AIDNS_VERDICT["$ip|$sid"]="0|NoCloudflare|$f_status"
        return
      fi
      if aidns_is_blocked_region "$region"; then
        AIDNS_VERDICT["$ip|$sid"]="0|RegionBlocked|$region"
        return
      fi
      if [[ ${#results[@]} -gt 1 ]]; then
        local s2
        IFS='|' read -r _ _ s2 _ _ _ <<<"${results[1]}"
        if [[ "$s2" -ge 500 ]]; then
          AIDNS_VERDICT["$ip|$sid"]="0|HttpStatus|$s2"
          return
        fi
      fi
      AIDNS_VERDICT["$ip|$sid"]="1|Region|$region"
      ;;
    GoogleWeb)
      if [[ "$f_status" -ge 400 ]]; then
        AIDNS_VERDICT["$ip|$sid"]="0|HttpStatus|$f_status"
        return
      fi
      if [[ -n "$region_from" ]]; then
        local api_v="${AIDNS_VERDICT[$ip|$region_from]:-}"
        if [[ -z "$api_v" ]]; then
          local geo_row
          if geo_row="$(aidns_service_by_id "$region_from")"; then
            aidns_test_service_access "$ip" "$geo_row"
            api_v="${AIDNS_VERDICT[$ip|$region_from]:-}"
          fi
        fi
        local aok areason
        IFS='|' read -r aok areason _ <<<"$api_v"
        if [[ "$aok" == "1" ]]; then
          AIDNS_VERDICT["$ip|$sid"]="1|GoogleRegionOk"
          return
        fi
        if [[ "$areason" == "GoogleRegionBlocked" ]]; then
          AIDNS_VERDICT["$ip|$sid"]="0|GoogleRegionBlocked"
          return
        fi
      fi
      if aidns_test_proxied "$address" "$domain"; then
        AIDNS_VERDICT["$ip|$sid"]="1|Proxied"
      else
        AIDNS_VERDICT["$ip|$sid"]="0|DirectGoogle"
      fi
      ;;
    OpenAiApi)
      if [[ "$f_head" == *unsupported_country* ]]; then
        AIDNS_VERDICT["$ip|$sid"]="0|OpenAiRegion"
        return
      fi
      if [[ "$f_status" == "401" ]]; then
        AIDNS_VERDICT["$ip|$sid"]="1|ApiResponds"
      else
        AIDNS_VERDICT["$ip|$sid"]="0|HttpStatus|$f_status"
      fi
      ;;
    AnthropicApi)
      if ! aidns_test_proxied "$address" "$domain"; then
        AIDNS_VERDICT["$ip|$sid"]="0|AnthropicDirect"
        return
      fi
      if [[ "$f_status" == "401" ]]; then
        AIDNS_VERDICT["$ip|$sid"]="1|ApiResponds"
      elif [[ "$f_status" == "403" ]]; then
        AIDNS_VERDICT["$ip|$sid"]="0|AnthropicRegion"
      else
        AIDNS_VERDICT["$ip|$sid"]="0|HttpStatus|$f_status"
      fi
      ;;
    GoogleApi)
      if [[ "$f_head" == *"location is not supported"* ]]; then
        AIDNS_VERDICT["$ip|$sid"]="0|GoogleRegionBlocked"
        return
      fi
      if [[ "$f_head" == *"API key not valid"* || "$f_head" == *"API_KEY_INVALID"* ]]; then
        AIDNS_VERDICT["$ip|$sid"]="1|ApiResponds"
      else
        AIDNS_VERDICT["$ip|$sid"]="0|HttpStatus|$f_status"
      fi
      ;;
    Generic)
      local region
      region="$(aidns_get_cloudflare_region "$f_head")"
      if [[ -n "$region" ]]; then
        if aidns_is_blocked_region "$region"; then
          AIDNS_VERDICT["$ip|$sid"]="0|RegionBlocked|$region"
          return
        fi
        if [[ ${#results[@]} -gt 1 ]]; then
          local s2
          IFS='|' read -r _ _ s2 _ _ _ <<<"${results[1]}"
          if [[ "$s2" -ge 500 ]]; then
            AIDNS_VERDICT["$ip|$sid"]="0|HttpStatus|$s2"
            return
          fi
        fi
        AIDNS_VERDICT["$ip|$sid"]="1|Region|$region"
        return
      fi
      if aidns_test_proxied "$address" "$domain"; then
        AIDNS_VERDICT["$ip|$sid"]="1|Proxied"
        return
      fi
      if [[ "$f_status" == "403" || "$f_status" == "451" ]]; then
        AIDNS_VERDICT["$ip|$sid"]="0|NotProxiedStatus|$f_status"
        return
      fi
      AIDNS_VERDICT["$ip|$sid"]="1|Direct"
      ;;
    Strict)
      local page="${results[-1]}"
      local p_status p_head
      IFS='|' read -r _ _ p_status _ _ p_head <<<"$page"
      local region
      region="$(aidns_get_cloudflare_region "$f_head")"
      if [[ -n "$region" ]] && aidns_is_blocked_region "$region"; then
        AIDNS_VERDICT["$ip|$sid"]="0|RegionBlocked|$region"
        return
      fi
      if [[ "$p_status" == "403" || "$p_status" == "451" ]]; then
        if ! aidns_test_cloudflare_challenge "$p_head"; then
          AIDNS_VERDICT["$ip|$sid"]="0|BlockedStatus|$p_status"
          return
        fi
      fi
      if [[ "$p_status" -ge 500 ]]; then
        AIDNS_VERDICT["$ip|$sid"]="0|HttpStatus|$p_status"
        return
      fi
      if [[ -n "$region" ]]; then
        AIDNS_VERDICT["$ip|$sid"]="1|Region|$region"
        return
      fi
      if aidns_test_proxied "$address" "$domain"; then
        AIDNS_VERDICT["$ip|$sid"]="1|Proxied"
      else
        AIDNS_VERDICT["$ip|$sid"]="1|Direct"
      fi
      ;;
    *)
      AIDNS_VERDICT["$ip|$sid"]="0|NoData"
      ;;
  esac
}

aidns_update_candidate_score() {
  local ip="$1"
  local -a gating
  mapfile -t gating < <(aidns_gating_ids)
  local weight=0 web=0 api=0
  local row
  for row in "${AIDNS_SERVICES[@]}"; do
    local mode sid group w
    mode="$(aidns_service_field "$row" 1)"
    [[ "$mode" == "Off" ]] && continue
    sid="$(aidns_service_field "$row" 0)"
    group="$(aidns_service_field "$row" 5)"
    w="$(aidns_service_field "$row" 4)"
    local v="${AIDNS_VERDICT[$ip|$sid]:-}"
    local ok
    IFS='|' read -r ok _ <<<"$v"
    [[ "$ok" == "1" ]] || continue
    if [[ "$mode" == "Required" ]]; then
      weight=$((weight + AIDNS_REQUIRED_WEIGHT))
    else
      weight=$((weight + w))
    fi
    local g
    local is_gating=0
    for g in "${gating[@]}"; do
      [[ "$g" == "$sid" ]] && is_gating=1 && break
    done
    if [[ "$is_gating" -eq 1 ]]; then
      web=$((web + 1))
    elif [[ "$group" == "Api" ]]; then
      api=$((api + 1))
    fi
  done
  local dns_cost=3000 tls_cost=3000
  [[ -n "${AIDNS_CAND_DNS_MS[$ip]:-}" ]] && dns_cost="${AIDNS_CAND_DNS_MS[$ip]}"
  [[ -n "${AIDNS_CAND_TLS_MS[$ip]:-}" ]] && tls_cost="${AIDNS_CAND_TLS_MS[$ip]}"
  AIDNS_CAND_SCORE["$ip"]=$((weight * 10000 - dns_cost - tls_cost))
  AIDNS_CAND_WEB["$ip"]="$web"
  AIDNS_CAND_API["$ip"]="$api"
  local mask=""
  for g in "${gating[@]}"; do
    local v="${AIDNS_VERDICT[$ip|$g]:-}"
    local ok
    IFS='|' read -r ok _ <<<"$v"
    if [[ "$ok" == "1" ]]; then mask+="1"; else mask+="0"; fi
  done
  AIDNS_CAND_MASK["$ip"]="$mask"
}

aidns_measure_candidates() {
  local ip
  for ip in "${AIDNS_CANDIDATE_IPS[@]}"; do
    [[ "${AIDNS_CAND_ALIVE[$ip]:-0}" -eq 1 ]] || continue
    local -a tls_samples=()
    local row
    for row in "${AIDNS_SERVICES[@]}"; do
      local mode sid domain checks
      mode="$(aidns_service_field "$row" 1)"
      sid="$(aidns_service_field "$row" 0)"
      domain="$(aidns_service_field "$row" 3)"
      checks="$(aidns_service_field "$row" 9)"
      # Always evaluate active + any we have DNS for
      local dns="${AIDNS_DNS_RESULT[$ip|$sid]:-}"
      [[ -n "$dns" ]] || continue
      aidns_test_service_access "$ip" "$row"
      local v="${AIDNS_VERDICT[$ip|$sid]:-}"
      local ok
      IFS='|' read -r ok _ <<<"$v"
      [[ "$ok" == "1" && "$mode" != "Off" ]] || continue
      local dok derr dips drtt
      IFS='|' read -r dok derr dips drtt <<<"$dns"
      local address="${dips%%,*}"
      local check
      IFS=';' read -ra check_arr <<<"$checks"
      for check in "${check_arr[@]}"; do
        [[ -z "$check" ]] && continue
        local path
        IFS=',' read -r path _ <<<"$check"
        local key https
        key="$(aidns_check_key "$address" "$domain" "$path")"
        https="${AIDNS_HTTPS_RESULT[$key]:-}"
        [[ -n "$https" ]] || continue
        local tls_ms
        IFS='|' read -r _ _ _ tls_ms _ _ <<<"$https"
        [[ -n "$tls_ms" ]] && tls_samples+=("$tls_ms")
      done
    done
    # shellcheck disable=SC2086
    AIDNS_CAND_TLS_MS["$ip"]="$(aidns_median ${tls_samples[@]:-})"
    aidns_update_candidate_score "$ip"
  done
}

aidns_show_candidate_table() {
  local -a gating
  mapfile -t gating < <(aidns_gating_ids)
  local -a ranked
  mapfile -t ranked < <(
    for ip in "${AIDNS_CANDIDATE_IPS[@]}"; do
      [[ "${AIDNS_CAND_ALIVE[$ip]:-0}" -eq 1 ]] || continue
      echo "${AIDNS_CAND_SCORE[$ip]:-0} $ip"
    done | sort -nr | awk '{print $2}'
  )
  local ip
  for ip in "${ranked[@]}"; do
    local web="${AIDNS_CAND_WEB[$ip]:-0}"
    local color="$AIDNS_C_GRAY"
    if [[ "$web" -eq ${#gating[@]} && ${#gating[@]} -gt 0 ]]; then
      color="$AIDNS_C_GREEN"
    elif [[ "$web" -gt 0 ]]; then
      color="$AIDNS_C_YELLOW"
    fi
    local marks="" g
    for g in "${gating[@]}"; do
      local v="${AIDNS_VERDICT[$ip|$g]:-}"
      local ok
      IFS='|' read -r ok _ <<<"$v"
      local name="$g"
      local row
      row="$(aidns_service_by_id "$g" || true)"
      [[ -n "$row" ]] && name="$(aidns_service_field "$row" 2)"
      if [[ "$ok" == "1" ]]; then marks+="  $name +"; else marks+="  $name -"; fi
    done
    local lat="${AIDNS_CAND_DNS_MS[$ip]:-}"
    local tls="${AIDNS_CAND_TLS_MS[$ip]:-}"
    local latency="-"
    if [[ -n "$lat" ]]; then
      latency="$((lat + ${tls:-0})) ms"
    fi
    local pname
    pname="$(aidns_provider_name_for_ip "$ip")"
    aidns_raw_line "  $(printf '%-15s %-15s' "$pname" "$ip")$marks  $latency" "$color" "TEST"
  done
}

# Outputs: primary secondary servers_csv missing_csv pinned_status
# Or empty if none work.
aidns_select_plan() {
  local pinned="${1:-}"
  local -a gating required
  mapfile -t gating < <(aidns_gating_ids)
  required=()
  local row
  for row in "${AIDNS_SERVICES[@]}"; do
    local mode sid
    mode="$(aidns_service_field "$row" 1)"
    [[ "$mode" == "Required" ]] || continue
    sid="$(aidns_service_field "$row" 0)"
    required+=("$sid")
  done

  local -a ranked good complete
  mapfile -t ranked < <(
    for ip in "${AIDNS_CANDIDATE_IPS[@]}"; do
      [[ "${AIDNS_CAND_ALIVE[$ip]:-0}" -eq 1 ]] || continue
      echo "${AIDNS_CAND_SCORE[$ip]:-0} $ip"
    done | sort -nr | awk '{print $2}'
  )
  good=()
  for ip in "${ranked[@]}"; do
    [[ "${AIDNS_CAND_WEB[$ip]:-0}" -gt 0 ]] && good+=("$ip")
  done
  if [[ ${#good[@]} -eq 0 ]]; then
    echo ""
    return 1
  fi

  complete=()
  for ip in "${good[@]}"; do
    local ok_all=1 sid
    for sid in "${required[@]}"; do
      local v="${AIDNS_VERDICT[$ip|$sid]:-}"
      local ok
      IFS='|' read -r ok _ <<<"$v"
      if [[ "$ok" != "1" ]]; then ok_all=0; break; fi
    done
    [[ "$ok_all" -eq 1 ]] && complete+=("$ip")
  done

  local primary="" pinned_status=""
  if [[ -n "$pinned" ]]; then
    local ip
    for ip in "${complete[@]}"; do
      if [[ "$(aidns_provider_id_for_ip "$ip")" == "$pinned" ]]; then
        primary="$ip"
        pinned_status="Used"
        break
      fi
    done
    if [[ -z "$primary" ]]; then
      pinned_status="Failed"
    fi
  fi
  if [[ -z "$primary" ]]; then
    if [[ ${#complete[@]} -gt 0 ]]; then
      primary="${complete[0]}"
    else
      # NoRoutes: primary that doesn't cover required -> Missing will list them
      primary="${good[0]}"
    fi
  fi

  local secondary=""
  local ip
  for ip in "${good[@]}"; do
    [[ "$ip" == "$primary" ]] && continue
    if [[ "${AIDNS_CAND_MASK[$ip]:-}" == "${AIDNS_CAND_MASK[$primary]:-}" ]]; then
      secondary="$ip"
      break
    fi
  done
  if [[ -z "$secondary" ]]; then
    for ip in "${good[@]}"; do
      [[ "$ip" == "$primary" ]] && continue
      secondary="$ip"
      break
    done
  fi

  local -a missing=()
  for sid in "${required[@]}"; do
    local v="${AIDNS_VERDICT[$primary|$sid]:-}"
    local ok
    IFS='|' read -r ok _ <<<"$v"
    [[ "$ok" == "1" ]] || missing+=("$sid")
  done

  local servers="$primary"
  [[ -n "$secondary" ]] && servers="$primary $secondary"
  local missing_csv
  missing_csv="$(IFS=','; echo "${missing[*]:-}")"
  printf "%s\n" "$primary|$secondary|$servers|$missing_csv|$pinned_status"
}

aidns_most_common_reason() {
  local sid="$1"
  declare -A counts=()
  local ip
  for ip in "${AIDNS_CANDIDATE_IPS[@]}"; do
    [[ "${AIDNS_CAND_ALIVE[$ip]:-0}" -eq 1 ]] || continue
    local v="${AIDNS_VERDICT[$ip|$sid]:-}"
    [[ -n "$v" ]] || continue
    local ok reason
    IFS='|' read -r ok reason _ <<<"$v"
    local text
    text="$(aidns_format_verdict "$ok" "$reason")"
    counts["$text"]=$(( ${counts[$text]:-0} + 1 ))
  done
  local best="—" best_n=0 k
  for k in "${!counts[@]}"; do
    if [[ "${counts[$k]}" -gt "$best_n" ]]; then
      best="$k"
      best_n="${counts[$k]}"
    fi
  done
  echo "$best"
}
