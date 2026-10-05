#!/usr/bin/env bash
# =============================================================================
# ike-bot · deploy manual a ECS Fargate (correr desde tu máquina)
#
#   ./deploy.sh                 tests → build ARM64 → push a ECR → deploy
#   ./deploy.sh --tag <tag>     redeploy de una imagen que ya está en ECR (rollback)
#   ./deploy.sh --stop          apaga el bot (desiredCount=0)
#
# Requiere: aws cli v2 con credenciales de internal-tools, docker con buildx.
# Variables: AWS_REGION (default us-east-1), AWS_PROFILE (opcional).
# =============================================================================
set -euo pipefail

: "${AWS_REGION:=us-east-1}"
export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION" AWS_PAGER=""
CLUSTER=ike-bot
SERVICE=ike-bot-discord
REPO=ike-bot

cd "$(dirname "$0")"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGISTRY="$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"

if [ "${1:-}" = "--stop" ]; then
  aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" --desired-count 0 >/dev/null
  echo "⏹  ike-bot apagado (desiredCount=0). ./deploy.sh lo vuelve a encender."
  exit 0
fi

TAG=""
if [ "${1:-}" = "--tag" ]; then
  TAG="${2:?Uso: ./deploy.sh --tag <tag>}"
  aws ecr describe-images --repository-name "$REPO" --image-ids "imageTag=$TAG" >/dev/null \
    || { echo "✘ No existe $REPO:$TAG en ECR" >&2; exit 1; }
  echo "↩︎  Redeploy de $TAG"
else
  TAG=$(git rev-parse --short HEAD 2>/dev/null || echo "manual-$(date +%Y%m%d%H%M%S)")
  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    TAG="$TAG-dirty-$(date +%Y%m%d%H%M%S)"   # el repo ECR es inmutable
    echo "⚠️  Hay cambios sin commitear → tag $TAG"
  fi

  if command -v uv >/dev/null; then
    echo "🧪 Tests"
    uv run pytest -q
  fi

  if aws ecr describe-images --repository-name "$REPO" --image-ids "imageTag=$TAG" >/dev/null 2>&1; then
    echo "♻️  $REPO:$TAG ya está en ECR, no se reconstruye"
  else
    echo "🔨 Build ARM64 + push $REPO:$TAG"
    aws ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null
    docker buildx build --platform linux/arm64 -t "$REGISTRY/$REPO:$TAG" --push .
  fi
fi

IMAGE="$REGISTRY/$REPO:$TAG"
TD_FILE=$(mktemp)
trap 'rm -f "$TD_FILE"' EXIT
sed -e "s|<ACCOUNT_ID>|$ACCOUNT_ID|g" -e "s|<REGION>|$AWS_REGION|g" -e "s|<IMAGE>|$IMAGE|g" \
  infra/task-definition.json > "$TD_FILE"

echo "📄 Registrando task definition"
TD_ARN=$(aws ecs register-task-definition --cli-input-json "file://$TD_FILE" \
  --query taskDefinition.taskDefinitionArn --output text)
echo "   $TD_ARN"

echo "🚀 Actualizando servicio"
aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" \
  --task-definition "$TD_ARN" --desired-count 1 >/dev/null

echo "⏳ Esperando a que el servicio quede estable (1-3 min)..."
if aws ecs wait services-stable --cluster "$CLUSTER" --services "$SERVICE"; then
  echo "✅ ike-bot desplegado: $IMAGE"
else
  echo "✘ El servicio no se estabilizó. Revisa:" >&2
  echo "   aws ecs describe-services --cluster $CLUSTER --services $SERVICE --query 'services[0].events[:5]'" >&2
  echo "   aws logs tail /ike-bot --since 15m" >&2
  exit 1
fi

echo
echo "Logs:  aws logs tail /ike-bot --follow"
