# Read / apply / restore /etc/systemd/resolved.conf for AI-DNS.

aidns_resolved_available() {
  [[ -f "$AIDNS_RESOLVED_CONF" ]] || command -v resolvectl >/dev/null 2>&1
}

aidns_current_dns() {
  if command -v resolvectl >/dev/null 2>&1; then
    local out
    out="$(resolvectl status 2>/dev/null | awk '
      /^[[:space:]]*DNS Servers:/ {
        for (i = 3; i <= NF; i++) if ($i ~ /^[0-9a-fA-F:.]+$/) print $i
      }
      /^[[:space:]]*Current DNS Server:/ { print $4 }
    ' | awk 'NF && $0 !~ /%/ { print }' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    if [[ -n "$out" ]]; then
      printf "%s\n" "$out"
      return
    fi
  fi
  if [[ -f "$AIDNS_RESOLVED_CONF" ]]; then
    awk -F= '
      /^[[:space:]]*DNS=/ {
        gsub(/\r/, "", $2)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
        print $2
        exit
      }
    ' "$AIDNS_RESOLVED_CONF"
    return
  fi
  printf "\n"
}

aidns_flush_dns_cache() {
  if command -v resolvectl >/dev/null 2>&1; then
    resolvectl flush-caches 2>/dev/null || true
  fi
  if command -v systemd-resolve >/dev/null 2>&1; then
    systemd-resolve --flush-caches 2>/dev/null || true
  fi
}

aidns_reload_resolved() {
  if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    systemctl reload-or-restart systemd-resolved 2>/dev/null \
      || systemctl restart systemd-resolved
  elif systemctl list-unit-files systemd-resolved.service >/dev/null 2>&1; then
    systemctl restart systemd-resolved 2>/dev/null || true
  fi
  aidns_flush_dns_cache
}

aidns_backup_resolved_file() {
  if [[ ! -f "$AIDNS_RESOLVED_CONF" ]]; then
    return 1
  fi
  if [[ -f "$AIDNS_RESOLVED_BACKUP" ]]; then
    return 0
  fi
  mkdir -p "$(dirname "$AIDNS_RESOLVED_BACKUP")"
  aidns_system_change "Backup $AIDNS_RESOLVED_CONF" \
    cp -a "$AIDNS_RESOLVED_CONF" "$AIDNS_RESOLVED_BACKUP"
}

# Write a cleaned resolved.conf with an AIDNS block. Args: DNS servers.
aidns_write_resolved_with_dns() {
  local conf="$AIDNS_RESOLVED_CONF"
  local -a servers=("$@")
  local dns_line
  dns_line="$(IFS=' '; echo "${servers[*]}")"

  local tmp
  tmp="$(mktemp)"
  # Drop previous AIDNS block and any active keys we manage so the AIDNS
  # values at the end of [Resolve] are the ones systemd-resolved uses.
  # DNSOverTLS=yes / DNSSEC=yes break plain UDP smart DNS (no DoT/DNSSEC).
  awk '
    BEGIN { skip=0 }
    /^# AIDNS-begin$/ { skip=1; next }
    /^# AIDNS-end$/ { skip=0; next }
    skip==1 { next }
    /^[[:space:]]*#/ { print; next }
    /^[[:space:]]*DNS=/ { next }
    /^[[:space:]]*FallbackDNS=/ { next }
    /^[[:space:]]*Domains=/ { next }
    /^[[:space:]]*DNSOverTLS=/ { next }
    /^[[:space:]]*DNSSEC=/ { next }
    { print }
  ' "$conf" >"$tmp"

  # Keep a single [Resolve] section: only create it when the file has none.
  # AIDNS lines are appended into that section (no second [Resolve] header).
  if ! grep -q '^\[Resolve\]' "$tmp"; then
    printf '\n[Resolve]\n' >>"$tmp"
  fi

  {
    printf '\n%s\n' "$AIDNS_RESOLVED_BEGIN"
    printf 'DNS=%s\n' "$dns_line"
    printf 'FallbackDNS=\n'
    printf 'Domains=~.\n'
    printf 'DNSOverTLS=no\n'
    printf 'DNSSEC=no\n'
    printf '%s\n' "$AIDNS_RESOLVED_END"
  } >>"$tmp"

  # mktemp creates 0600; systemd expects a world-readable resolved.conf (0644).
  chmod 644 "$tmp"
  mv -f "$tmp" "$conf"
}

# Apply DNS servers into resolved.conf between AIDNS markers.
aidns_apply_resolved_dns() {
  local -a servers=("$@")
  if [[ ${#servers[@]} -eq 0 ]]; then
    return 1
  fi
  if [[ ! -f "$AIDNS_RESOLVED_CONF" ]]; then
    aidns_fail "Error.NoResolved"
    return 1
  fi

  local dns_line
  dns_line="$(IFS=' '; echo "${servers[*]}")"
  if [[ "$AIDNS_DRY_RUN" -eq 1 ]]; then
    aidns_note "Common.DryRunChange" "Set resolved.conf DNS to $dns_line"
    return 0
  fi

  aidns_trace "change: Set resolved.conf DNS to $dns_line"
  aidns_write_resolved_with_dns "${servers[@]}"
  aidns_reload_resolved
}

aidns_restore_resolved() {
  if [[ -f "$AIDNS_RESOLVED_BACKUP" ]]; then
    if [[ "$AIDNS_DRY_RUN" -eq 1 ]]; then
      aidns_note "Common.DryRunChange" "Restore $AIDNS_RESOLVED_CONF from backup"
      return 0
    fi
    aidns_trace "change: Restore $AIDNS_RESOLVED_CONF from backup"
    cp -a "$AIDNS_RESOLVED_BACKUP" "$AIDNS_RESOLVED_CONF"
    aidns_reload_resolved
    return 0
  fi

  if [[ ! -f "$AIDNS_RESOLVED_CONF" ]]; then
    return 1
  fi
  if ! grep -q "^${AIDNS_RESOLVED_BEGIN}$" "$AIDNS_RESOLVED_CONF" 2>/dev/null; then
    return 1
  fi

  if [[ "$AIDNS_DRY_RUN" -eq 1 ]]; then
    aidns_note "Common.DryRunChange" "Remove AIDNS block from $AIDNS_RESOLVED_CONF"
    return 0
  fi

  aidns_trace "change: Remove AIDNS block from $AIDNS_RESOLVED_CONF"
  local tmp
  tmp="$(mktemp)"
  awk '
    BEGIN { skip=0 }
    /^# AIDNS-begin$/ { skip=1; next }
    /^# AIDNS-end$/ { skip=0; next }
    skip==0 { print }
  ' "$AIDNS_RESOLVED_CONF" >"$tmp"
  chmod 644 "$tmp"
  mv -f "$tmp" "$AIDNS_RESOLVED_CONF"
  aidns_reload_resolved
  return 0
}

aidns_resolved_has_aidns() {
  [[ -f "$AIDNS_RESOLVED_CONF" ]] && grep -q "^${AIDNS_RESOLVED_BEGIN}$" "$AIDNS_RESOLVED_CONF" 2>/dev/null
}
