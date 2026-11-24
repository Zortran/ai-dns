#!/usr/bin/env bash
# Find a working smart DNS and apply it via systemd-resolved.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$DIR/ai-dns.sh" --action Enable "$@"
