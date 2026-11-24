#!/usr/bin/env bash
# Full rollback, clear caches, then select a resolver from scratch.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$DIR/ai-dns.sh" --action Update "$@"
