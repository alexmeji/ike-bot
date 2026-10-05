#!/usr/bin/env bash
# =============================================================================
# ike-bot · role ike-bot-invoker en la cuenta de un PRODUCTO (pay, axis, ...)
#
# Permite que el task role de ike-bot (cuenta internal-tools) invoque SOLO
# el runtime de AgentCore indicado. Idempotente. Correr con credenciales
# de la cuenta del producto.
#
# Uso:
#   BOT_ACCOUNT_ID=111111111111 \
#   RUNTIME_ARN=arn:aws:bedrock-agentcore:us-east-1:222222222222:runtime/pay_support-XXXX \
#   ./infra/invoker-role.sh
# =============================================================================
set -euo pipefail

: "${BOT_ACCOUNT_ID:?Define BOT_ACCOUNT_ID (cuenta internal-tools)}"
: "${RUNTIME_ARN:?Define RUNTIME_ARN (runtime de AgentCore del producto)}"
export AWS_PAGER=""
ROLE=ike-bot-invoker
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
case "$RUNTIME_ARN" in
  *":$ACCOUNT_ID:"*) ;;
  *) echo "✘ RUNTIME_ARN no es de esta cuenta ($ACCOUNT_ID). ¿Credenciales correctas?" >&2; exit 1 ;;
esac

cat > "$TMP/trust.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "AWS": "arn:aws:iam::$BOT_ACCOUNT_ID:role/ike-bot-task" },
    "Action": "sts:AssumeRole"
  }]
}
EOF

cat > "$TMP/policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "InvocarSoloEsteAgente",
    "Effect": "Allow",
    "Action": "bedrock-agentcore:InvokeAgentRuntime",
    "Resource": ["$RUNTIME_ARN", "$RUNTIME_ARN/*"]
  }]
}
EOF

if aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  aws iam update-assume-role-policy --role-name "$ROLE" --policy-document "file://$TMP/trust.json"
  echo "✔ $ROLE ya existía (trust re-aplicada)"
else
  aws iam create-role --role-name "$ROLE" \
    --description "ike-bot (cuenta $BOT_ACCOUNT_ID) puede invocar el agente de este producto" \
    --assume-role-policy-document "file://$TMP/trust.json" \
    --tags Key=App,Value=ike-bot >/dev/null
  echo "✔ $ROLE creado"
fi
aws iam put-role-policy --role-name "$ROLE" --policy-name invoke-agent \
  --policy-document "file://$TMP/policy.json"
echo "✔ policy aplicada"

cat <<EOF

Agrega esta ruta en el parámetro /ike-bot/routes (cuenta $BOT_ACCOUNT_ID):

  "discord:<CHANNEL_ID>": {
    "product": "<pay|axis>",
    "runtime_arn": "$RUNTIME_ARN",
    "role_arn": "arn:aws:iam::$ACCOUNT_ID:role/$ROLE"
  }

y cambia RESPONDER a "agentcore" en infra/task-definition.json + ./deploy.sh
EOF
