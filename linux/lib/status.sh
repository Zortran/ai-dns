# Status: show current DNS / state and check services through the system resolver.

aidns_status() {
  aidns_need_cmd dig curl python3 || return 1

  local primary provider servers
  primary="$(aidns_state_primary)"
  provider="$(aidns_state_primary_provider)"
  servers="$(aidns_state_servers)"
  local current
  current="$(aidns_current_dns)"

  if [[ -n "$primary" ]] || aidns_resolved_has_aidns; then
    aidns_ok "Status.Enabled" "${primary:-?}" "${provider:-?}"
  else
    aidns_note "Status.NotEnabled"
  fi
  aidns_ok "Status.Dns" "${current:-$(aidns_text Common.None)}"
  if [[ -n "$servers" ]]; then
    aidns_note "Apply.Dns" "$servers"
  fi

  aidns_probe_init
  trap 'aidns_probe_cleanup' RETURN

  # Reference + system verify for gating services
  local -a domains=()
  local row
  for row in "${AIDNS_SERVICES[@]}"; do
    local mode
    mode="$(aidns_service_field "$row" 1)"
    [[ "$mode" == "Off" ]] && continue
    domains+=("$(aidns_service_field "$row" 3)")
  done
  mapfile -t domains < <(printf "%s\n" "${domains[@]:-}" | sort -u)
  if [[ ${#domains[@]} -gt 0 ]]; then
    aidns_get_reference_answers "${domains[@]}"
  fi

  local -a gating
  mapfile -t gating < <(aidns_gating_ids)
  local working=0 failed=0
  local sid
  for sid in "${gating[@]}"; do
    local grow name domain checks mode
    grow="$(aidns_service_by_id "$sid")"
    name="$(aidns_service_field "$grow" 2)"
    domain="$(aidns_service_field "$grow" 3)"
    checks="$(aidns_service_field "$grow" 9)"
    mode="$(aidns_service_field "$grow" 1)"
    local ips
    ips="$(aidns_system_resolve "$domain")"
    if [[ -z "$ips" ]]; then
      aidns_warn "Verify.Fails" "$name" "$(aidns_text Verdict.DnsNoAnswer timeout)"
      [[ "$mode" == "Required" ]] && failed=$((failed + 1))
      continue
    fi
    local addr="${ips%%,*}"
    local check
    IFS=';' read -ra check_arr <<<"$checks"
    for check in "${check_arr[@]}"; do
      [[ -z "$check" ]] && continue
      local path maxb=8192 rest headers_raw=""
      path="${check%%,*}"; rest="${check#"$path"}"; rest="${rest#,}"
      maxb="${rest%%,*}"; [[ "$maxb" =~ ^[0-9]+$ ]] || maxb=8192
      headers_raw="${rest#"$maxb"}"; headers_raw="${headers_raw#,}"
      local key out
      key="$(aidns_check_key "$addr" "$domain" "$path")"
      out="$(mktemp)"
      local -a hdrs=()
      if [[ -n "$headers_raw" ]]; then
        while [[ "$headers_raw" =~ ^([^:]+:[^,]+)(,(.*))?$ ]]; do
          hdrs+=("${BASH_REMATCH[1]}")
          headers_raw="${BASH_REMATCH[3]}"
          [[ -z "$headers_raw" ]] && break
        done
      fi
      aidns_https_probe_to_file "$addr" "$domain" "$path" "$maxb" "$out" "${hdrs[@]:-}"
      AIDNS_HTTPS_RESULT["$key"]="$(cat "$out")"
      rm -f "$out"
    done
    AIDNS_DNS_RESULT["$addr|$sid"]="1|None|$ips|0"
    aidns_test_service_access "$addr" "$grow"
    local v="${AIDNS_VERDICT[$addr|$sid]:-}"
    local ok reason rest
    IFS='|' read -r ok reason rest <<<"$v"
    local text
    # shellcheck disable=SC2086
    text="$(aidns_format_verdict "$ok" "$reason" ${rest//|/ })"
    if [[ "$ok" == "1" ]]; then
      aidns_ok "Verify.Works" "$name" "$text"
      working=$((working + 1))
    else
      aidns_warn "Verify.Fails" "$name" "$text"
      [[ "$mode" == "Required" ]] && failed=$((failed + 1))
    fi
  done

  printf "\n"
  aidns_note "Status.Hint"
  if [[ "$failed" -gt 0 ]]; then
    return 3
  fi
  return 0
}
