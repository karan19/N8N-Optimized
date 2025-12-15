#!/bin/bash
set -e
BACKUP_TABLE="N8N-Optimized-Backup"
AWS_REGION="us-west-2"
N8N_DATA_DIR="/opt/n8n/data"

echo "[$(date)] Starting export to DynamoDB..."

# Helper function to put item
put_item() {
  local PK=$1
  local FILE=$2
  local IS_BINARY=$3
  
  if [ ! -s "$FILE" ] || [ "$(cat "$FILE")" == "[]" ]; then
    return
  fi

  # Use Python to construct the JSON item safely to handle escaping
  if [ "$IS_BINARY" == "true" ]; then
     DATA_B64=$(base64 -w 0 "$FILE")
     python3 -c "import json, sys; print(json.dumps({'pk': {'S': '$PK'}, 'data': {'S': '$DATA_B64'}, 'updated_at': {'S': '$(date -u +%Y-%m-%dT%H:%M:%SZ)'}}))" > /tmp/${PK}_item.json
  else
     # For text/JSON, read file content into data string
     python3 -c "import json, sys; print(json.dumps({'pk': {'S': '$PK'}, 'data': {'S': sys.stdin.read()}, 'updated_at': {'S': '$(date -u +%Y-%m-%dT%H:%M:%SZ)'}}))" < "$FILE" > /tmp/${PK}_item.json
  fi

  aws dynamodb put-item \
    --table-name "$BACKUP_TABLE" \
    --item "file:///tmp/${PK}_item.json" \
    --region "$AWS_REGION"
    
  echo "[$(date)] $PK backed up"
}

# Export workflows (clean capture)
# 1. Export to file inside container to avoid log pollution
docker exec -u node n8n-n8n-1 n8n export:workflow --all --output=/home/node/workflows.json > /dev/null 2>&1
# 2. Copy out
docker cp n8n-n8n-1:/home/node/workflows.json /tmp/workflows.json
# 3. Upload
put_item "workflows" "/tmp/workflows.json" "false"

# Export credentials (clean capture)
docker exec -u node n8n-n8n-1 n8n export:credentials --all --output=/home/node/credentials.json --decrypted > /dev/null 2>&1
docker cp n8n-n8n-1:/home/node/credentials.json /tmp/credentials.json
put_item "credentials" "/tmp/credentials.json" "false"

# Backup SQLite database
if [ -f "$N8N_DATA_DIR/database.sqlite" ]; then
  put_item "database_sqlite" "$N8N_DATA_DIR/database.sqlite" "true"
fi

echo "[$(date)] Export complete"
