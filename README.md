# ike-bot · ʻIke

**ʻIke** ("conocimiento, saber" en hawaiano) es el bot de soporte interno de
Aloha. El equipo le escribe `@ike ...` en el chat y el bot enruta la pregunta
al agente del producto (Pay, Axis) según el canal. Hoy: Discord. Después:
Slack, con el mismo core.

```
Discord ──WebSocket saliente──► ike-bot (ECS Fargate · internal-tools)
                                   │ core/routes: "discord:<canal>" → producto
                                   │ AssumeRole ike-bot-invoker
                                   ▼
                                AgentCore runtime del producto (pay, axis)
```

Sin ALB, sin puertos de entrada, sin dominio.

## Estructura

```
src/ike_bot/
├── __main__.py            python -m ike_bot <discord|slack>
├── core/
│   ├── request.py         Request, Route, Reply, Responder
│   ├── routes.py          carga rutas de SSM o archivo
│   └── responders.py      EchoResponder, AgentCoreResponder
└── adapters/
    └── discord.py         @menciones, hilos, permisos por rol
infra/
├── README.md              instrucciones para crear la infraestructura
├── bootstrap.sh           crea todo en internal-tools (idempotente)
├── invoker-role.sh        role en la cuenta de cada producto
├── task-definition.json   plantilla de la task (env, secretos, logs)
└── policies/              policies IAM
deploy.sh                  deploy manual: build → push → ECS
assets/                    avatares del bot
```

## 1. Bot en Discord

1. https://discord.com/developers/applications → **New Application** → `ʻIke`.
2. **Información general:** ícono `assets/ike-avatar.png`, descripción y
   etiquetas. **URL de interacciones: vacía** (usamos el Gateway).
3. **Bot:** username `ike`, *Reset Token* (guárdalo para el bootstrap),
   **Public Bot: off**, **Message Content Intent: on**.
4. **Instalación:** solo *Guild Install*.
5. **OAuth2 → URL Generator** → scope `bot`, permisos: View Channels,
   Send Messages, Create Public Threads, Send Messages in Threads,
   Read Message History. Abre la URL e invítalo al servidor.
6. Dale acceso solo a los canales de soporte.

## 2. Correr local

```bash
cp .env.example .env          # pega DISCORD_TOKEN
uv sync
uv run --env-file .env python -m ike_bot discord
uv run pytest                  # tests
```

Sin rutas responde en cualquier canal (modo desarrollo). Para probar el
ruteo: *Developer Mode* en Discord → click derecho al canal → *Copy ID*,
crea `routes.json` desde `routes.example.json` y pon `ROUTES_FILE=routes.json`.

> Apaga el bot de producción (`./deploy.sh --stop`) mientras pruebas en local
> con el mismo token, o respondería dos veces.

## 3. Infraestructura (una sola vez)

Ver [`infra/README.md`](infra/README.md). Resumen:

```bash
VPC_ID=vpc-xxx SUBNET_IDS=subnet-a,subnet-b DISCORD_CHANNEL_ID=<canal> ./infra/bootstrap.sh
```

## 4. Deploy (manual)

```bash
./deploy.sh                 # tests → build ARM64 → push a ECR → actualiza el servicio
./deploy.sh --tag <tag>     # rollback a una imagen anterior
./deploy.sh --stop          # apagar el bot
```

El tag de la imagen es el SHA corto del commit (o `-dirty-<fecha>` si hay
cambios sin commitear). Requiere aws cli v2 con credenciales de
internal-tools y Docker con buildx.

**Configuración** (env, `RESPONDER`, roles permitidos): se cambia en
`infra/task-definition.json` y se aplica con `./deploy.sh`.
**Rutas:** se cambian en SSM (`/ike-bot/routes`) y se aplican reiniciando:
`./deploy.sh --tag <tag actual>`.

## 5. Operación

```bash
aws logs tail /ike-bot --follow                                   # logs
aws ecs describe-services --cluster ike-bot --services ike-bot-discord \
  --query 'services[0].events[:5]'                                # eventos

# Terminal dentro del contenedor (requiere session-manager-plugin)
TASK=$(aws ecs list-tasks --cluster ike-bot --service-name ike-bot-discord --query 'taskArns[0]' --output text)
aws ecs execute-command --cluster ike-bot --task "$TASK" --container ike-bot --interactive --command /bin/sh
```

| Síntoma | Causa probable |
|---|---|
| La task arranca y se detiene | Revisa `aws logs tail /ike-bot`; token inválido o falta el secreto |
| Conectado pero los mensajes llegan vacíos | Falta **Message Content Intent** en Discord |
| No responde en el canal | El ID en `/ike-bot/routes` no coincide (en hilos se usa el canal padre) |
| Responde dos veces | Hay otra copia corriendo (¿local con el mismo token?) |

## 6. Rutas

Clave `<plataforma>:<channel_id>`. Canal sin ruta = el bot no responde ahí.

```json
{
  "discord:1290000000000000001": {
    "product": "pay",
    "runtime_arn": "arn:aws:bedrock-agentcore:us-east-1:495197194137:runtime/ike_sandbox-XXXXXXXXXX",
    "role_arn": "arn:aws:iam::495197194137:role/ike-bot-invoker"
  },
  "discord:1290000000000000002": {
    "product": "axis",
    "runtime_arn": "arn:aws:bedrock-agentcore:us-east-1:495197194137:runtime/ike_sandbox-XXXXXXXXXX",
    "role_arn": "arn:aws:iam::495197194137:role/ike-bot-invoker"
  }
}
```

## 7. Conectar un agente

1. En la cuenta del producto: `./infra/invoker-role.sh` (ver `infra/README.md`).
2. Agrega la ruta con `runtime_arn` y `role_arn` en SSM.
3. `RESPONDER=agentcore` en `infra/task-definition.json` → `./deploy.sh`.

Contrato con el agente:

- **Payload:** `{"prompt": "...", "requested_by": "discord:<user_id>", "product": "<route.product>"}`
  - `product` viene de la ruta del canal; el agente responde "no conozco ese producto" si no lo tiene.
- **Respuesta:** `{"result": "<texto>", "display"?: {"text": "<texto>", "embeds": [Embed]}}`
  - `Embed` = `{"title", "description"?, "fields": [{"name", "value", "inline"}], "footer"?}`.
  - Sin `display`: se envía `result` (en trozos de ≤2000 caracteres).
  - Con `display`: se envía `display.text` y luego los embeds (≤10 por mensaje); `result` no se envía
    (repite la tabla como texto). El bot recorta a los límites de Discord si el agente se pasa.
  - El core solo ve dicts neutrales; el adaptador los dibuja (Discord embeds hoy, Block Kit en Slack).
- **Sesión:** `runtimeSessionId` = id del hilo → el agente conserva contexto.

## 8. Agregar Slack (futuro)

1. `adapters/slack.py` con Slack Bolt en **Socket Mode** (sin endpoint
   público), escuchando `app_mention` y respondiendo en `thread_ts`, con
   `route_key="slack:<channel>"`, `session_id="slack-thread-<channel>-<ts>"`,
   `requested_by="slack:<user>"`.
2. Agregar `"slack"` en `ADAPTERS` (`__main__.py`) y `slack-bolt` a dependencias.
3. Tokens de Slack en el secreto `ike-bot/env`.
4. Un segundo servicio `ike-bot-slack` (copia de la task con `command: ["slack"]`).
