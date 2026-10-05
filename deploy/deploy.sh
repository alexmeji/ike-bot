#!/bin/bash
# Se ejecuta EN la EC2 (vía SSM Run Command desde CI).
# Uso: /opt/aloha-support-bot/deploy.sh <imagen-ecr:tag>
set -euo pipefail

export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
IMAGE="$1"
REGISTRY="${IMAGE%%/*}"
BASE=/opt/aloha-support-bot
PLATFORMS=(discord)   # agregar "slack" cuando exista el adaptador

aws ecr get-login-password | docker login -u AWS --password-stdin "$REGISTRY"

# Secreto en Secrets Manager en formato KEY=valor por línea
aws secretsmanager get-secret-value --secret-id aloha-support-bot/env \
  --query SecretString --output text > "$BASE/.env"
chmod 600 "$BASE/.env"

docker pull "$IMAGE"

for p in "${PLATFORMS[@]}"; do
  name="support-bot-$p"
  # rm antes de run: nunca dos bots conectados a la vez (respondería doble)
  docker rm -f "$name" 2>/dev/null || true
  docker run -d --name "$name" --restart unless-stopped \
    --env-file "$BASE/.env" \
    --log-driver awslogs \
    --log-opt awslogs-group=/aloha-support-bot \
    --log-opt awslogs-stream="$p" \
    --log-opt awslogs-create-group=true \
    "$IMAGE" "$p"
done

docker image prune -af --filter "until=72h" >/dev/null
echo "Desplegado $IMAGE"
