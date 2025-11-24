#!/bin/bash

# Resolve absolute path
COMPOSE_FILE=$(readlink -f docker-compose.yml)
COMPOSE_DIR=$(dirname "$COMPOSE_FILE")

# The cron command: Reload nginx every day at 3AM
JOB="0 3 * * * cd $COMPOSE_DIR && /usr/local/bin/docker-compose exec -T waf nginx -s reload"

# Check if job already exists (Idempotent check)
crontab -l 2>/dev/null | grep -F "$JOB" >/dev/null

if [ $? -ne 0 ]; then
    (crontab -l 2>/dev/null; echo "$JOB") | crontab -
    echo "✅ Cron job added successfully."
else
    echo "👌 Cron job already exists. Skipping."
fi