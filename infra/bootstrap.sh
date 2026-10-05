#!/usr/bin/env bash
# =============================================================================
# ike-bot · bootstrap de infraestructura (cuenta internal-tools)
#
# Crea, o verifica si ya existen:
#   ECR repo, log group, secreto, parámetro de rutas, 2 roles IAM,
#   security group, cluster ECS, task definition inicial y servicio Fargate.
#
# Es IDEMPOTENTE: si un recurso ya existe, lo deja como está (las policies
# IAM y el lifecycle de ECR sí se re-aplican). NUNCA borra nada.
#
# El servicio queda con desiredCount=0. El primer ./deploy.sh sube la imagen
# y lo pone en 1.
#
# Uso:
#   VPC_ID=vpc-xxx SUBNET_IDS=subnet-aaa,subnet-bbb \
#   DISCORD_TOKEN=xxxx DISCORD_CHANNEL_ID=1290... \
#   ./infra/bootstrap.sh
#
# Variables:
#   AWS_REGION          (opcional, default us-east-1)
#   AWS_PROFILE         (opcional, perfil de la cuenta internal-tools)
#   VPC_ID              (requerida)
#   SUBNET_IDS          (requerida) subnets PÚBLICAS (con ruta a un IGW), separadas por coma
#   DISCORD_TOKEN       (requerida solo la primera vez; si no está, se pide por teclado)
#   DISCORD_CHANNEL_ID  (opcional) canal de soporte de Pay para la ruta inicial
# =============================================================================
set -euo pipefail

: "${AWS_REGION:=us-east-1}"
: "${VPC_ID:?Define VPC_ID}"
: "${SUBNET_IDS:?Define SUBNET_IDS (subnets públicas separadas por coma)}"
DISCORD_TOKEN="${DISCORD_TOKEN:-}"
DISCORD_CHANNEL_ID="${DISCORD_CHANNEL_ID:-}"
export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"
export AWS_PAGER=""

NAME=ike-bot
CLUSTER=ike-bot
SERVICE=ike-bot-discord
TASK_FAMILY=ike-bot-discord
LOG_GROUP=/ike-bot
SECRET=ike-bot/env
ROUTES_PARAM=/ike-bot/routes
EXEC_ROLE=ike-bot-execution
TASK_ROLE=ike-bot-task
SG_NAME=ike-bot-sg
TAGS_KV="Key=App,Value=ike-bot"

HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32m✔\033[0m %s\n' "$*"; }
warn() { printf '    \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\n\033[31m✘ %s\033[0m\n' "$*" >&2; exit 1; }

render() { # render <template> <destino> [image]
  sed -e "s|<ACCOUNT_ID>|$ACCOUNT_ID|g" -e "s|<REGION>|$AWS_REGION|g" -e "s|<IMAGE>|${3:-}|g" "$1" > "$2"
}

command -v aws >/dev/null || die "Falta aws cli v2"

# --- 0. Contexto -------------------------------------------------------------
log "Contexto"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGISTRY="$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
ok "Cuenta $ACCOUNT_ID · región $AWS_REGION · VPC $VPC_ID"

# --- 1. Validar subnets públicas ---------------------------------------------
log "Validando subnets"
IFS=',' read -ra SUBNETS <<< "$SUBNET_IDS"
for s in "${SUBNETS[@]}"; do
  vpc=$(aws ec2 describe-subnets --subnet-ids "$s" --query 'Subnets[0].VpcId' --output text)
  [ "$vpc" = "$VPC_ID" ] || die "La subnet $s no pertenece a $VPC_ID"
  rt=$(aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=$s" \
        --query 'RouteTables[0].RouteTableId' --output text)
  if [ "$rt" = "None" ]; then
    rt=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" "Name=association.main,Values=true" \
          --query 'RouteTables[0].RouteTableId' --output text)
  fi
  igw=$(aws ec2 describe-route-tables --route-table-ids "$rt" \
        --query "length(RouteTables[0].Routes[?starts_with(GatewayId || '', 'igw-')])" --output text)
  [ "$igw" != "0" ] || die "La subnet $s no tiene ruta a un Internet Gateway (no es pública). El bot necesita salir a internet."
  ok "$s es pública (route table $rt)"
done

# --- 2. ECR --------------------------------------------------------------------
log "ECR: $NAME"
if aws ecr describe-repositories --repository-names "$NAME" >/dev/null 2>&1; then
  ok "ya existe"
else
  aws ecr create-repository --repository-name "$NAME" \
    --image-scanning-configuration scanOnPush=true \
    --image-tag-mutability IMMUTABLE \
    --tags "$TAGS_KV" >/dev/null
  ok "creado"
fi
aws ecr put-lifecycle-policy --repository-name "$NAME" --lifecycle-policy-text \
  '{"rules":[{"rulePriority":1,"description":"Conservar las ultimas 20 imagenes","selection":{"tagStatus":"any","countType":"imageCountMoreThan","countNumber":20},"action":{"type":"expire"}}]}' \
  >/dev/null
ok "lifecycle: conserva las últimas 20 imágenes"

# --- 3. Logs -------------------------------------------------------------------
log "CloudWatch Logs: $LOG_GROUP"
exists=$(aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" \
          --query "length(logGroups[?logGroupName=='$LOG_GROUP'])" --output text)
if [ "$exists" = "0" ]; then
  aws logs create-log-group --log-group-name "$LOG_GROUP" --tags App=ike-bot
  ok "creado"
else
  ok "ya existe"
fi
aws logs put-retention-policy --log-group-name "$LOG_GROUP" --retention-in-days 30
ok "retención 30 días"

# --- 4. Secreto ----------------------------------------------------------------
log "Secrets Manager: $SECRET"
if aws secretsmanager describe-secret --secret-id "$SECRET" >/dev/null 2>&1; then
  if [ -n "$DISCORD_TOKEN" ]; then
    aws secretsmanager put-secret-value --secret-id "$SECRET" \
      --secret-string "$(printf '{"DISCORD_TOKEN":"%s"}' "$DISCORD_TOKEN")" >/dev/null
    ok "ya existía; DISCORD_TOKEN actualizado"
  else
    ok "ya existe (no se tocó)"
  fi
else
  if [ -z "$DISCORD_TOKEN" ]; then
    read -rsp "    DISCORD_TOKEN: " DISCORD_TOKEN; echo
  fi
  [ -n "$DISCORD_TOKEN" ] || die "DISCORD_TOKEN vacío"
  aws secretsmanager create-secret --name "$SECRET" \
    --description "ike-bot: credenciales (JSON)" \
    --secret-string "$(printf '{"DISCORD_TOKEN":"%s"}' "$DISCORD_TOKEN")" \
    --tags "$TAGS_KV" >/dev/null
  ok "creado"
fi

# --- 5. Rutas ------------------------------------------------------------------
log "SSM Parameter: $ROUTES_PARAM"
if aws ssm get-parameter --name "$ROUTES_PARAM" >/dev/null 2>&1; then
  ok "ya existe (no se sobrescribe; edítalo en la consola de SSM)"
else
  if [ -n "$DISCORD_CHANNEL_ID" ]; then
    ROUTES=$(printf '{"discord:%s":{"product":"pay"}}' "$DISCORD_CHANNEL_ID")
  else
    ROUTES='{}'
    warn "Sin DISCORD_CHANNEL_ID: rutas vacías = MODO DESARROLLO (el bot responde en cualquier canal)"
  fi
  aws ssm put-parameter --name "$ROUTES_PARAM" --type String --value "$ROUTES" \
    --description "ike-bot: canal -> agente" --tags "$TAGS_KV" >/dev/null
  ok "creado: $ROUTES"
fi

# --- 6. IAM --------------------------------------------------------------------
log "IAM roles"
render "$HERE/policies/ecs-tasks-trust.json"  "$TMP/trust.json"
render "$HERE/policies/execution-inline.json" "$TMP/exec.json"
render "$HERE/policies/task-inline.json"      "$TMP/task.json"

NEW_ROLE=0
ensure_role() {
  if aws iam get-role --role-name "$1" >/dev/null 2>&1; then
    aws iam update-assume-role-policy --role-name "$1" --policy-document "file://$TMP/trust.json"
    ok "$1 ya existe (trust policy re-aplicada)"
  else
    aws iam create-role --role-name "$1" --description "$2" \
      --assume-role-policy-document "file://$TMP/trust.json" --tags "$TAGS_KV" >/dev/null
    NEW_ROLE=1
    ok "$1 creado"
  fi
}
ensure_role "$EXEC_ROLE" "ike-bot: ECS pull de imagen, logs y secreto"
aws iam attach-role-policy --role-name "$EXEC_ROLE" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
aws iam put-role-policy --role-name "$EXEC_ROLE" --policy-name ike-bot-secret \
  --policy-document "file://$TMP/exec.json"
ok "$EXEC_ROLE: policies aplicadas"

ensure_role "$TASK_ROLE" "ike-bot: permisos del contenedor (rutas, agentes, ECS Exec)"
aws iam put-role-policy --role-name "$TASK_ROLE" --policy-name ike-bot-task \
  --policy-document "file://$TMP/task.json"
ok "$TASK_ROLE: policies aplicadas"

if [ "$NEW_ROLE" = "1" ]; then
  warn "Esperando 15s a que IAM propague los roles nuevos..."
  sleep 15
fi

# --- 7. Security group ---------------------------------------------------------
log "Security group: $SG_NAME"
SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$SG_NAME" \
  --query 'SecurityGroups[0].GroupId' --output text)
if [ "$SG_ID" = "None" ]; then
  SG_ID=$(aws ec2 create-security-group --group-name "$SG_NAME" --vpc-id "$VPC_ID" \
    --description "ike-bot: sin entrada, solo salida" \
    --tag-specifications "ResourceType=security-group,Tags=[{$TAGS_KV}]" \
    --query GroupId --output text)
  ok "creado $SG_ID (sin reglas de entrada; salida abierta por default)"
else
  ingress=$(aws ec2 describe-security-groups --group-ids "$SG_ID" \
    --query 'length(SecurityGroups[0].IpPermissions)' --output text)
  [ "$ingress" = "0" ] || warn "$SG_ID tiene reglas de ENTRADA; el bot no las necesita, revísalas"
  ok "ya existe $SG_ID"
fi

# --- 8. Cluster ----------------------------------------------------------------
log "ECS cluster: $CLUSTER"
status=$(aws ecs describe-clusters --clusters "$CLUSTER" --query 'clusters[0].status' --output text)
if [ "$status" = "ACTIVE" ]; then
  ok "ya existe"
else
  aws ecs create-cluster --cluster-name "$CLUSTER" \
    --capacity-providers FARGATE FARGATE_SPOT \
    --tags key=App,value=ike-bot >/dev/null
  ok "creado"
fi

# --- 9. Task definition inicial -----------------------------------------------
log "Task definition: $TASK_FAMILY"
if aws ecs describe-task-definition --task-definition "$TASK_FAMILY" >/dev/null 2>&1; then
  ok "ya existe (deploy.sh registra las nuevas revisiones)"
else
  render "$HERE/task-definition.json" "$TMP/td.json" "$REGISTRY/$NAME:bootstrap"
  aws ecs register-task-definition --cli-input-json "file://$TMP/td.json" >/dev/null
  ok "registrada (imagen placeholder; el primer deploy la reemplaza)"
fi

# --- 10. Servicio --------------------------------------------------------------
log "ECS service: $SERVICE"
svc=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].status' --output text)
if [ "$svc" = "ACTIVE" ]; then
  ok "ya existe (no se modifica)"
else
  aws ecs create-service --cluster "$CLUSTER" --service-name "$SERVICE" \
    --task-definition "$TASK_FAMILY" \
    --desired-count 0 \
    --launch-type FARGATE --platform-version LATEST \
    --deployment-configuration "minimumHealthyPercent=0,maximumPercent=100,deploymentCircuitBreaker={enable=true,rollback=true}" \
    --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_IDS],securityGroups=[$SG_ID],assignPublicIp=ENABLED}" \
    --enable-execute-command \
    --propagate-tags SERVICE \
    --tags key=App,value=ike-bot >/dev/null
  ok "creado con desiredCount=0"
  ok "minimumHealthyPercent=0 / maximumPercent=100 → nunca dos bots a la vez"
fi

# --- Resumen -------------------------------------------------------------------
cat <<EOF

$(printf '\033[1;32m')Infraestructura lista.$(printf '\033[0m')

  Cuenta          $ACCOUNT_ID ($AWS_REGION)
  ECR             $REGISTRY/$NAME
  Cluster         $CLUSTER
  Servicio        $SERVICE (desiredCount=0 hasta el primer deploy)
  Security group  $SG_ID
  Task role       arn:aws:iam::$ACCOUNT_ID:role/$TASK_ROLE
  Secreto         $SECRET
  Rutas           $ROUTES_PARAM
  Logs            $LOG_GROUP

Siguiente paso, desde la raíz del repo:
  ./deploy.sh

Para conectar el agente de un producto, en ESA cuenta:
  BOT_ACCOUNT_ID=$ACCOUNT_ID RUNTIME_ARN=<arn del runtime> ./infra/invoker-role.sh
EOF
