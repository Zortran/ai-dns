#!/usr/bin/env bash
# Show current DNS and check services (no root required).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$DIR/ai-dns.sh" --action Status --no-wait "$@"
