# infra — instrucciones para el agente de infraestructura

Objetivo: dejar corriendo **ike-bot** (bot de Discord de soporte interno) en
**ECS Fargate** en la cuenta **internal-tools**.

## Qué se crea

| Recurso | Nombre | Notas |
|---|---|---|
| ECR | `ike-bot` | tags inmutables, scan on push, conserva 20 imágenes |
| CloudWatch Logs | `/ike-bot` | retención 30 días |
| Secrets Manager | `ike-bot/env` | JSON `{"DISCORD_TOKEN": "..."}` |
| SSM Parameter | `/ike-bot/routes` | JSON de rutas canal → agente |
| IAM role | `ike-bot-execution` | ECS: pull de ECR, logs, leer el secreto |
| IAM role | `ike-bot-task` | contenedor: leer rutas, asumir `ike-bot-invoker` en cuentas de producto, ECS Exec |
| Security group | `ike-bot-sg` | **sin reglas de entrada**, salida abierta |
| ECS cluster | `ike-bot` | Fargate |
| ECS service | `ike-bot-discord` | 1 task ARM64, 0.25 vCPU / 0.5 GB, IP pública, **sin ALB** |

No hay ALB, NAT, dominio ni puertos de entrada: el bot solo abre una conexión
WebSocket **saliente** a Discord. La IP pública es para salir a internet.

`minimumHealthyPercent=0` / `maximumPercent=100` es intencional: nunca deben
correr dos copias del bot (cada mensaje se respondería dos veces).

## Pasos

1. **Credenciales** de la cuenta internal-tools (perfil de AWS CLI o SSO).
   Verifica: `aws sts get-caller-identity`.

2. **Elegir red:** una VPC y 1-2 **subnets públicas** (con ruta a un Internet
   Gateway). El script valida que lo sean y se detiene si no.

   ```bash
   aws ec2 describe-subnets --query 'Subnets[].[SubnetId,VpcId,AvailabilityZone,MapPublicIpOnLaunch]' --output table
   ```

3. **Correr el bootstrap** desde la raíz del repo:

   ```bash
   VPC_ID=vpc-xxxxxxxx \
   SUBNET_IDS=subnet-aaaa,subnet-bbbb \
   DISCORD_CHANNEL_ID=<id del canal de soporte de Pay> \
   ./infra/bootstrap.sh
   ```

   - `DISCORD_TOKEN` se pide por teclado si no viene en el entorno (mejor así,
     para que no quede en el historial del shell).
   - Es idempotente: se puede volver a correr sin riesgo. No borra nada.

4. **Primer deploy:** `./deploy.sh` (lo hace Alex o el agente, desde la raíz del repo).

5. **Verificar:**

   ```bash
   aws ecs describe-services --cluster ike-bot --services ike-bot-discord \
     --query 'services[0].[status,runningCount,desiredCount]'
   aws logs tail /ike-bot --since 10m     # debe decir "Discord conectado como ..."
   ```

## Más adelante: conectar el agente de un producto

En la cuenta del producto (ej. Pay), con sus credenciales:

```bash
BOT_ACCOUNT_ID=<cuenta internal-tools> \
RUNTIME_ARN=<arn del runtime de AgentCore> \
./infra/invoker-role.sh
```

Imprime la ruta exacta a agregar en `/ike-bot/routes`. Después: cambiar
`RESPONDER` a `agentcore` en `infra/task-definition.json` y `./deploy.sh`.

## Restricciones

- No crear ALB, NAT Gateway ni reglas de entrada en el security group.
- No usar la cuenta de administración de la Organization.
- No guardar el token de Discord en archivos del repo ni en variables de entorno de la task (va por Secrets Manager).
