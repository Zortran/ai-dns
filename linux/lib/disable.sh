# Disable: restore resolved.conf, hosts, IPv6 and remove data.

aidns_sysctl_enable_ipv6() {
  if [[ "$AIDNS_DRY_RUN" -eq 1 ]]; then
    aidns_note "Common.DryRunChange" "sysctl net.ipv6.conf.all.disable_ipv6=0"
    return 0
  fi
  sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null
  sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null
}

aidns_disable() {
  local keep_logs="${1:-0}"

  if [[ "$AIDNS_FULL" -eq 1 ]]; then
    aidns_warn "Disable.FullMode"
  fi

  aidns_step "Step.FindBackup"
  local created=""
  if aidns_backup_exists; then
    created="$(aidns_read_backup_created)"
    aidns_ok "Disable.BackupFound" "$created"
  else
    aidns_warn "Disable.NoBackup"
  fi

  local changes=0
  aidns_step "Step.Resolved"
  if aidns_restore_resolved; then
    if [[ -f "$AIDNS_RESOLVED_BACKUP" ]]; then
      aidns_ok "Disable.ResolvedRestored"
    else
      aidns_ok "Disable.ResolvedCleared"
    fi
    changes=$((changes + 1))
  else
    aidns_note "Disable.NoBackup"
  fi

  # IPv6
  local ipv6_ours=0
  if [[ -f "$AIDNS_BACKUP" ]]; then
    ipv6_ours="$(aidns_bool_to_int "$(aidns_json_get "$AIDNS_BACKUP" "ipv6DisabledByUs" "false")")"
  fi
  if [[ "$ipv6_ours" -eq 1 || "$AIDNS_ENABLE_IPV6" -eq 1 ]]; then
    if aidns_sysctl_enable_ipv6; then
      aidns_ok "Disable.Ipv6On"
    else
      aidns_fail "Disable.Ipv6Failed" "sysctl"
    fi
  fi

  aidns_step "Step.Hosts"
  local delete=0
  [[ "$AIDNS_FULL" -eq 1 ]] && delete=1
  local hc
  hc="$(aidns_restore_hosts_entries "$delete" || echo 0)"
  if [[ "$hc" == "0" ]]; then
    aidns_ok "Disable.HostsNone"
  elif [[ "$delete" -eq 1 ]]; then
    aidns_ok "Disable.HostsDeleted" "$hc"
  else
    aidns_ok "Disable.HostsRestored" "$hc"
  fi

  aidns_step "Step.Caches"
  if aidns_flush_dns_cache; then
    aidns_ok "Disable.CachesCleared"
  else
    aidns_warn "Disable.CachesFailed" "flush"
  fi

  aidns_step "Step.Data"
  if [[ ! -d "$AIDNS_DATA_ROOT" ]]; then
    aidns_ok "Disable.DataNone"
  elif [[ "$AIDNS_ERRORS" -gt 0 && "$AIDNS_FULL" -eq 0 ]]; then
    aidns_warn "Disable.DataKept" "$AIDNS_DATA_ROOT"
  else
    if aidns_remove_data "$keep_logs"; then
      if [[ "$keep_logs" -eq 1 ]]; then
        aidns_ok "Disable.DataRemovedKeepLogs" "$AIDNS_LOGS_DEFAULT"
      else
        aidns_ok "Disable.DataRemoved" "$AIDNS_DATA_ROOT"
      fi
    else
      aidns_warn "Disable.DataLocked" "$AIDNS_DATA_ROOT"
    fi
  fi

  aidns_step "Step.Summary"
  if [[ "$AIDNS_DRY_RUN" -eq 1 ]]; then
    aidns_ok "Disable.DryRunDone" "$changes"
    if [[ "$AIDNS_ERRORS" -eq 0 ]]; then return 0; else return 3; fi
  fi

  local current remaining=0
  current="$(aidns_current_dns)"
  # Check if still pointing at known smart DNS from previous state if file still exists
  local known=""
  if [[ -f "$AIDNS_STATE" ]]; then
    known="$(aidns_state_servers)"
  fi
  local ip
  for ip in $current; do
    for k in $known; do
      if [[ "$ip" == "$k" ]]; then
        remaining=$((remaining + 1))
        aidns_warn "Disable.Remaining" "$current"
        break 2
      fi
    done
  done
  if [[ "$remaining" -eq 0 ]]; then
    aidns_ok "Status.Dns" "${current:-$(aidns_text Common.None)}"
  fi

  if dig +time=2 +tries=1 +short A "$AIDNS_PROBE_DOMAIN" >/dev/null 2>&1; then
    aidns_ok "Disable.DnsWorks"
  else
    aidns_warn "Disable.DnsNotYet"
  fi

  printf "\n"
  if [[ "$AIDNS_ERRORS" -eq 0 && "$remaining" -eq 0 ]]; then
    aidns_ok "Disable.Clean"
  else
    aidns_warn "Common.CompletedWithIssues" "$AIDNS_ERRORS"
  fi
  aidns_note "Common.RestartBrowser"
  if [[ "$AIDNS_ERRORS" -eq 0 && "$remaining" -eq 0 ]]; then return 0; else return 3; fi
}
