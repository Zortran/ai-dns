#!/usr/bin/env bash
# Restore original DNS settings and remove AI-DNS traces.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$DIR/ai-dns.sh" --action Disable "$@"
