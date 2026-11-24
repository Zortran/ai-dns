# backup.json — pre-change snapshot for exact rollback.

aidns_read_backup_created() {
  if [[ ! -f "$AIDNS_BACKUP" ]]; then
    echo ""
    return
  fi
  aidns_json_get "$AIDNS_BACKUP" "created" ""
}

aidns_backup_exists() {
  [[ -f "$AIDNS_BACKUP" ]]
}

aidns_write_backup() {
  local created hosts_modified ipv6_disabled
  created="${1:-$(aidns_now_iso)}"
  hosts_modified="${2:-false}"
  ipv6_disabled="${3:-false}"
  local dns
  dns="$(aidns_current_dns)"
  local hostname
  hostname="$(hostname 2>/dev/null || echo unknown)"

  local json
  json="$(python3 - "$created" "$hostname" "$dns" "$hosts_modified" "$ipv6_disabled" <<'PY'
import json, sys
created, host, dns, hosts_mod, ipv6 = sys.argv[1:6]
doc = {
  "schemaVersion": 3,
  "created": created,
  "computer": host,
  "resolvedDns": dns,
  "hostsModified": hosts_mod.lower() == "true",
  "ipv6DisabledByUs": ipv6.lower() == "true",
}
print(json.dumps(doc, ensure_ascii=False, indent=2))
PY
)"
  aidns_json_write "$AIDNS_BACKUP" "$json"
}

aidns_update_backup_flags() {
  if [[ ! -f "$AIDNS_BACKUP" ]]; then
    return
  fi
  local hosts_modified="${1:-}"
  local ipv6_disabled="${2:-}"
  if [[ "$AIDNS_DRY_RUN" -eq 1 ]]; then
    return
  fi
  python3 - "$AIDNS_BACKUP" "$hosts_modified" "$ipv6_disabled" <<'PY'
import json, sys
path, hosts, ipv6 = sys.argv[1:4]
with open(path, encoding="utf-8") as f:
    doc = json.load(f)
if hosts in ("true", "false"):
    doc["hostsModified"] = hosts == "true"
if ipv6 in ("true", "false"):
    doc["ipv6DisabledByUs"] = ipv6 == "true"
with open(path, "w", encoding="utf-8") as f:
    json.dump(doc, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
}
