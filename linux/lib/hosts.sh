# Comment out / restore /etc/hosts entries that would override smart DNS.

aidns_managed_domains() {
  local row domain
  for row in "${AIDNS_SERVICES[@]}"; do
    local mode
    mode="$(aidns_service_field "$row" 1)"
    [[ "$mode" == "Off" ]] && continue
    domain="$(aidns_service_field "$row" 3)"
    echo "$domain"
    echo "www.$domain"
  done | sort -u
}

aidns_disable_hosts_entries() {
  if [[ ! -f "$AIDNS_HOSTS_FILE" ]]; then
    echo 0
    return
  fi
  local domains
  mapfile -t domains < <(aidns_managed_domains)
  if [[ ${#domains[@]} -eq 0 ]]; then
    echo 0
    return
  fi

  if [[ "$AIDNS_DRY_RUN" -eq 1 ]]; then
    aidns_note "Common.DryRunChange" "Comment conflicting hosts entries"
    echo 0
    return
  fi

  if [[ ! -f "$AIDNS_HOSTS_BACKUP" ]]; then
    mkdir -p "$(dirname "$AIDNS_HOSTS_BACKUP")"
    cp -a "$AIDNS_HOSTS_FILE" "$AIDNS_HOSTS_BACKUP"
  fi

  local count
  count="$(python3 - "$AIDNS_HOSTS_FILE" "$AIDNS_HOSTS_MARKER" "${domains[@]}" <<'PY'
import sys
path = sys.argv[1]
marker = sys.argv[2]
domains = set(sys.argv[3:])
changed = 0
out = []
with open(path, encoding="utf-8", errors="replace") as f:
    for line in f:
        raw = line.rstrip("\n")
        stripped = raw.lstrip()
        if stripped.startswith("#") or not stripped:
            out.append(raw)
            continue
        parts = stripped.split()
        if len(parts) < 2:
            out.append(raw)
            continue
        names = [p.lower().rstrip(".") for p in parts[1:]]
        if any(n in domains for n in names):
            out.append(marker + raw)
            changed += 1
        else:
            out.append(raw)
with open(path, "w", encoding="utf-8") as f:
    f.write("\n".join(out) + "\n")
print(changed)
PY
)"
  echo "$count"
}

aidns_restore_hosts_entries() {
  local delete_mode="${1:-0}"
  if [[ ! -f "$AIDNS_HOSTS_FILE" ]]; then
    echo 0
    return
  fi
  if ! grep -qF "$AIDNS_HOSTS_MARKER" "$AIDNS_HOSTS_FILE" 2>/dev/null; then
    echo 0
    return
  fi

  if [[ "$AIDNS_DRY_RUN" -eq 1 ]]; then
    aidns_note "Common.DryRunChange" "Restore hosts entries"
    echo 0
    return
  fi

  local count
  count="$(python3 - "$AIDNS_HOSTS_FILE" "$AIDNS_HOSTS_MARKER" "$delete_mode" <<'PY'
import sys
path, marker, delete = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
changed = 0
out = []
with open(path, encoding="utf-8", errors="replace") as f:
    for line in f:
        raw = line.rstrip("\n")
        if raw.startswith(marker):
            changed += 1
            if not delete:
                out.append(raw[len(marker):])
            # delete mode: drop the line
        else:
            out.append(raw)
with open(path, "w", encoding="utf-8") as f:
    f.write("\n".join(out) + ("\n" if out else ""))
print(changed)
PY
)"
  echo "$count"
}
