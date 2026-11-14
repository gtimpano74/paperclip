#!/bin/sh
set -e

mkdir -p /paperclip/instances/default/logs
chown -R node:node /paperclip

CONFIG_PATH="/paperclip/instances/default/config.json"
BOOTSTRAP_MARKER="/paperclip/instances/default/.ceo-bootstrap-done"

# Existing installs from before this marker already ran the bootstrap.
if [ -f "$CONFIG_PATH" ] && [ ! -f "$BOOTSTRAP_MARKER" ]; then
  touch "$BOOTSTRAP_MARKER"
  chown node:node "$BOOTSTRAP_MARKER"
fi

# Only write the default config on first boot, so edits survive restarts.
if [ ! -f "$CONFIG_PATH" ]; then
  PUBLIC_URL="${PAPERCLIP_PUBLIC_URL:-http://localhost:3100}"
  cat > "$CONFIG_PATH" <<CONF
{
  "\$meta": { "version": 1, "updatedAt": "2026-01-01T00:00:00Z", "source": "onboard" },
  "database": { "mode": "postgres", "backup": { "enabled": true, "intervalMinutes": 60, "retentionDays": 7, "dir": "/paperclip/instances/default/data/backups" } },
  "logging": { "mode": "file", "logDir": "/paperclip/instances/default/logs" },
  "server": { "deploymentMode": "authenticated", "exposure": "public", "bind": "lan", "host": "0.0.0.0", "port": 3100, "serveUi": true },
  "auth": { "baseUrlMode": "explicit", "publicBaseUrl": "${PUBLIC_URL}", "disableSignUp": false },
  "storage": { "provider": "local_disk", "localDisk": { "baseDir": "/paperclip/instances/default/data/storage" } },
  "secrets": { "provider": "local_encrypted", "strictMode": false, "localEncrypted": { "keyFilePath": "/paperclip/instances/default/secrets/master.key" } },
  "telemetry": { "enabled": false }
}
CONF
  chown node:node "$CONFIG_PATH"
fi

gosu node node --import ./server/node_modules/tsx/dist/loader.mjs server/dist/index.js &
SERVER_PID=$!

until wget -qO /dev/null http://localhost:3100/api/health 2>/dev/null; do
  sleep 2
done

# Create the CEO invite only once. A failed run leaves no marker, so it retries next boot.
if [ ! -f "$BOOTSTRAP_MARKER" ]; then
  if gosu node node --import ./server/node_modules/tsx/dist/loader.mjs -e "
import { bootstrapCeoInvite } from './cli/src/commands/auth-bootstrap-ceo.js';
bootstrapCeoInvite({ expiresHours: 72 }).catch(e => { console.error('Bootstrap error:', e.message); process.exitCode = 1; });
" 2>&1; then
    touch "$BOOTSTRAP_MARKER"
    chown node:node "$BOOTSTRAP_MARKER"
  else
    echo "Bootstrap failed; will retry on next boot"
  fi
else
  echo "CEO invite already bootstrapped; skipping"
fi

wait $SERVER_PID
