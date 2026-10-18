#!/bin/bash
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/homelab-common.sh" || exit 1
[[ "$ENABLED" == true ]] || exit 0
[[ -n "$WEBHOOK_URL" ]] || { echo "WEBHOOK_URL is missing in $CONFIG_FILE" >&2; exit 1; }
[[ -n "${1:-}" ]] || { echo "Usage: $0 MESSAGE" >&2; exit 1; }
HOST=$(hostname) || exit 1
STAMP=$(date '+%Y-%m-%d %H:%M:%S') || exit 1
# JSON encoding also handles tabs, control characters and hostnames.
PAYLOAD=$(python3 - "$HOST" "$STAMP" "$1" <<'JSON'
import json, sys
print(json.dumps({'content': f'**[{sys.argv[1]}]** {sys.argv[2]}\n{sys.argv[3]}', 'allowed_mentions': {'parse': []}}))
JSON
) || exit 1
curl --fail --silent --show-error --connect-timeout 5 --max-time 10 \
    -H 'Content-Type: application/json' --data-binary "$PAYLOAD" "$WEBHOOK_URL" >/dev/null
