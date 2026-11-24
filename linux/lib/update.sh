# Update: full disable, clear caches, enable with fresh feeds.

aidns_update() {
  AIDNS_FULL=1
  local code
  set +e
  aidns_disable 1
  code=$?
  set -e
  # Continue even if disable returned 3
  if [[ "$code" -eq 1 ]]; then
    return 1
  fi

  aidns_ensure_data_dirs
  aidns_clear_cache

  # Fresh enable with refresh
  set +e
  aidns_enable 1
  code=$?
  set -e
  return "$code"
}
