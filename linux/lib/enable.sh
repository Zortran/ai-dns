# Enable: discover, probe, select, apply resolved.conf, verify.

aidns_sysctl_disable_ipv6() {
  if [[ "$AIDNS_DRY_RUN" -eq 1 ]]; then
    aidns_note "Common.DryRunChange" "sysctl net.ipv6.conf.all.disable_ipv6=1"
    return 0
  fi
  sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null
  sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null
}

aidns_dead_dns_recovery() {
  local -a alive=("$@")
  local current
  current="$(aidns_current_dns)"
  local hit=0 ip a
  for ip in $current; do
    # if current DNS is a known candidate that is not alive — recover
    local is_known=0 is_alive=0
    for a in "${AIDNS_CANDIDATE_IPS[@]:-}"; do
      [[ "$a" == "$ip" ]] && is_known=1 && break
    done
    [[ "$is_known" -eq 0 ]] && continue
    for a in "${alive[@]:-}"; do
      [[ "$a" == "$ip" ]] && is_alive=1 && break
    done
    if [[ "$is_alive" -eq 0 ]]; then
      hit=1
      break
    fi
  done
  if [[ "$hit" -eq 0 ]] && ! aidns_resolved_has_aidns; then
    aidns_note "Recovery.Untouched"
    return
  fi
  if [[ "$hit" -eq 0 ]]; then
    aidns_note "Recovery.Untouched"
    return
  fi
  aidns_warn "Recovery.Restoring"
  if aidns_restore_resolved; then
    aidns_ok "Recovery.Restored"
  fi
}

# Sets AIDNS_VERIFY_WORKING (int) and AIDNS_VERIFY_FAILED (comma-separated names).
# Status lines go to the terminal; do not capture stdout of this function.
AIDNS_VERIFY_WORKING=0
AIDNS_VERIFY_FAILED=""

aidns_verify_system() {
  local -a gating
  mapfile -t gating < <(aidns_gating_ids)
  local working=0
  local -a required_failed=()
  local sid
  for sid in "${gating[@]}"; do
    local row name domain kind checks
    row="$(aidns_service_by_id "$sid")"
    name="$(aidns_service_field "$row" 2)"
    domain="$(aidns_service_field "$row" 3)"
    kind="$(aidns_service_field "$row" 6)"
    checks="$(aidns_service_field "$row" 9)"
    local ips
    ips="$(aidns_system_resolve "$domain")"
    if [[ -z "$ips" ]]; then
      aidns_warn "Verify.Fails" "$name" "$(aidns_text Verdict.DnsNoAnswer timeout)"
      local mode
      mode="$(aidns_service_field "$row" 1)"
      if [[ "$mode" == "Required" ]]; then
        required_failed+=("$name")
      fi
      continue
    fi
    local addr="${ips%%,*}"
    AIDNS_DNS_RESULT["system|$sid"]="1|None|$ips|0"
    AIDNS_CAND_ALIVE["system"]=1
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
    local fake_ip="$addr"
    AIDNS_DNS_RESULT["$fake_ip|$sid"]="1|None|$ips|0"
    aidns_test_service_access "$fake_ip" "$row"
    local v="${AIDNS_VERDICT[$fake_ip|$sid]:-}"
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
    fi
    local mode
    mode="$(aidns_service_field "$row" 1)"
    if [[ "$mode" == "Required" && "$ok" != "1" ]]; then
      required_failed+=("$name")
    fi
  done
  AIDNS_VERIFY_WORKING="$working"
  if [[ ${#required_failed[@]} -gt 0 ]]; then
    local IFS=','
    AIDNS_VERIFY_FAILED="${required_failed[*]}"
  else
    AIDNS_VERIFY_FAILED=""
  fi
}

aidns_enable() {
  local refresh="${1:-0}"

  if [[ "$AIDNS_TEST_ONLY" -eq 1 ]]; then
    aidns_warn "Enable.TestOnly"
  fi
  local -a skipped=()
  [[ "$AIDNS_SETTING_DISABLE_IPV6" -eq 0 ]] && skipped+=("DisableIpv6")
  [[ "$AIDNS_SETTING_HOSTS" -eq 0 ]] && skipped+=("Hosts")
  if [[ ${#skipped[@]} -gt 0 ]]; then
    aidns_note "Enable.SystemSkipped" "$(IFS=', '; echo "${skipped[*]}")"
  fi

  aidns_step "Step.Prepare"
  if ! aidns_resolved_available; then
    if [[ "$AIDNS_TEST_ONLY" -eq 1 || "$AIDNS_DRY_RUN" -eq 1 ]]; then
      aidns_warn "Error.NoResolved"
    else
      aidns_fail "Error.NoResolved"
      return 1
    fi
  fi
  local cur
  cur="$(aidns_current_dns)"
  if [[ -n "$cur" ]]; then
    aidns_ok "Prepare.CurrentDns" "$cur"
  else
    aidns_note "Prepare.NoResolved"
  fi
  aidns_need_cmd dig curl python3 || return 1
  aidns_ok "Prepare.Ready"
  aidns_probe_init
  trap 'aidns_probe_cleanup' RETURN

  aidns_step "Step.Catalog"
  aidns_get_provider_catalog "$refresh" "$AIDNS_OFFLINE"

  aidns_step "Step.Reference"
  local -a domains=("$AIDNS_PROBE_DOMAIN")
  local row
  for row in "${AIDNS_SERVICES[@]}"; do
    local mode
    mode="$(aidns_service_field "$row" 1)"
    [[ "$mode" == "Off" ]] && continue
    domains+=("$(aidns_service_field "$row" 3)")
  done
  # unique
  mapfile -t domains < <(printf "%s\n" "${domains[@]}" | sort -u)
  aidns_get_reference_answers "${domains[@]}"
  local -a gating
  mapfile -t gating < <(aidns_gating_ids)
  local referenced=0 g
  for g in "${gating[@]}"; do
    local grow gdom
    grow="$(aidns_service_by_id "$g")"
    gdom="$(aidns_service_field "$grow" 3)"
    [[ -n "${AIDNS_REFERENCE[$gdom]:-}" ]] && referenced=$((referenced + 1))
  done
  if [[ "$referenced" -eq 0 ]]; then
    aidns_warn "Reference.Intercepted"
  else
    aidns_ok "Reference.Received" "$referenced" "${#gating[@]}"
  fi
  local discovered
  discovered="$(aidns_discover_provider_ips)"
  aidns_ok "Reference.Candidates" "${#AIDNS_CANDIDATE_IPS[@]}" "$discovered"

  aidns_step "Step.Probe"
  aidns_probe_candidates_dns
  local alive_count=0 dead_list=""
  local ip
  local -a alive_ips=()
  for ip in "${AIDNS_CANDIDATE_IPS[@]}"; do
    if [[ "${AIDNS_CAND_ALIVE[$ip]:-0}" -eq 1 ]]; then
      alive_count=$((alive_count + 1))
      alive_ips+=("$ip")
    else
      dead_list+="$(aidns_provider_name_for_ip "$ip")($ip), "
    fi
  done
  aidns_ok "Probe.Alive" "$alive_count" "${#AIDNS_CANDIDATE_IPS[@]}"
  if [[ -n "$dead_list" ]]; then
    aidns_note "Probe.Dead" "${dead_list%, }"
  fi
  if [[ "$alive_count" -eq 0 ]]; then
    aidns_fail "Probe.NoneAlive"
    if [[ "$AIDNS_TEST_ONLY" -eq 0 ]]; then
      aidns_dead_dns_recovery
    fi
    return 2
  fi

  aidns_step "Step.Https"
  aidns_https_batch
  local https_count=${#AIDNS_HTTPS_RESULT[@]}
  aidns_ok "Https.Done" "$https_count"

  aidns_measure_candidates
  printf "\n"
  aidns_show_candidate_table

  local plan
  plan="$(aidns_select_plan "$AIDNS_SETTING_PINNED_PROVIDER" || true)"
  if [[ -z "$plan" ]]; then
    printf "\n"
    aidns_fail "Plan.NoneWorks"
    for g in "${gating[@]}"; do
      local grow gname
      grow="$(aidns_service_by_id "$g")"
      gname="$(aidns_service_field "$grow" 2)"
      aidns_note "Plan.CommonReason" "$gname" "$(aidns_most_common_reason "$g")"
    done
    if [[ "$AIDNS_TEST_ONLY" -eq 0 ]]; then
      aidns_dead_dns_recovery "${alive_ips[@]:-}"
    fi
    return 2
  fi

  local primary secondary servers missing pinned_status
  IFS='|' read -r primary secondary servers missing pinned_status <<<"$plan"

  if [[ -n "$missing" ]]; then
    printf "\n"
    aidns_fail "Plan.NoneWorks"
    local m
    IFS=',' read -ra miss_arr <<<"$missing"
    for m in "${miss_arr[@]}"; do
      [[ -z "$m" ]] && continue
      local grow gname
      grow="$(aidns_service_by_id "$m")"
      gname="$(aidns_service_field "$grow" 2)"
      aidns_note "Plan.CommonReason" "$gname" "$(aidns_most_common_reason "$m")"
    done
    if [[ "$AIDNS_TEST_ONLY" -eq 0 ]]; then
      aidns_dead_dns_recovery "${alive_ips[@]:-}"
    fi
    return 2
  fi

  printf "\n"
  aidns_ok "Plan.Primary" "$primary" "$(aidns_provider_name_for_ip "$primary")"
  if [[ -n "$secondary" ]]; then
    aidns_ok "Plan.Secondary" "$secondary" "$(aidns_provider_name_for_ip "$secondary")"
  fi
  if [[ "$pinned_status" == "Used" ]]; then
    aidns_note "Plan.PinnedUsed" "$(aidns_provider_name_for_ip "$primary")"
  elif [[ "$pinned_status" == "Failed" ]]; then
    aidns_warn "Plan.PinnedFailed" "$AIDNS_SETTING_PINNED_PROVIDER"
  fi

  if [[ "$AIDNS_TEST_ONLY" -eq 1 ]]; then
    aidns_ok "Enable.TestDone" "$(aidns_elapsed)"
    return 0
  fi

  aidns_step "Step.Backup"
  aidns_ensure_data_dirs
  if aidns_backup_exists; then
    aidns_note "Backup.Kept" "$(aidns_read_backup_created)"
  else
    aidns_backup_resolved_file || true
    aidns_write_backup "$(aidns_now_iso)" "false" "false"
    if [[ -n "$cur" ]]; then
      aidns_ok "Prepare.CurrentDns" "$cur"
    else
      aidns_ok "Backup.Dhcp"
    fi
    aidns_ok "Backup.Resolved"
  fi
  aidns_ok "Backup.Saved" "$AIDNS_BACKUP"

  aidns_step "Step.Apply"
  # shellcheck disable=SC2086
  aidns_apply_resolved_dns $servers
  aidns_ok "Apply.Dns" "$servers"

  if [[ "$AIDNS_SETTING_DISABLE_IPV6" -eq 1 ]]; then
    if aidns_sysctl_disable_ipv6; then
      aidns_update_backup_flags "" "true"
      aidns_ok "Apply.Ipv6Off"
    else
      aidns_fail "Apply.Ipv6Failed" "sysctl"
    fi
  fi

  if [[ "$AIDNS_SETTING_HOSTS" -eq 1 ]]; then
    local hc
    hc="$(aidns_disable_hosts_entries)"
    if [[ "$hc" -gt 0 ]]; then
      aidns_update_backup_flags "true" ""
      aidns_ok "Apply.Hosts" "$hc"
    fi
  fi

  aidns_write_state "$primary" "$(aidns_provider_name_for_ip "$primary")" $servers

  aidns_step "Step.Verify"
  if [[ "$AIDNS_DRY_RUN" -eq 1 ]]; then
    aidns_note "Verify.DryRun"
    return 0
  fi
  aidns_flush_dns_cache
  sleep 1
  AIDNS_VERIFY_WORKING=0
  AIDNS_VERIFY_FAILED=""
  aidns_verify_system
  local working="${AIDNS_VERIFY_WORKING:-0}"
  local failed="${AIDNS_VERIFY_FAILED:-}"
  [[ "$working" =~ ^[0-9]+$ ]] || working=0

  printf "\n"
  if [[ "$AIDNS_ERRORS" -eq 0 && "$working" -gt 0 && -z "$failed" ]]; then
    aidns_ok "Verify.Done" "$(aidns_elapsed)" "$working" "${#gating[@]}" ""
    aidns_note "Common.RestartBrowser"
    aidns_note "Verify.HowToUndo"
    return 0
  fi
  if [[ -n "$failed" ]]; then
    aidns_warn "Verify.RequiredFails" "$failed"
  fi
  aidns_warn "Common.CompletedWithIssues" "$AIDNS_ERRORS"
  return 3
}
