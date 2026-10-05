# aloha-support-bot · ʻIke

**ʻIke** ("conocimiento, saber" en hawaiano) es el bot de soporte interno de Aloha. El equipo
le escribe `@ike ...` en el chat y el bot enruta la pregunta al agente del producto (Pay, Axis) según el
canal. Hoy: Discord. Después: Slack, con el mismo core.

```
Discord ──► adapters/discord.py ─┐
Slack   ──► adapters/slack.py  ──┤  (futuro)
                                 ▼
                core/routes.py   "discord:<canal>" → producto + runtime + role
                core/responders  echo | agentcore (AssumeRole → InvokeAgentRuntime)
```

## Estructura

```
src/support_bot/
├── __main__.py            python -m support_bot <discord|slack>
├── core/
│   ├── request.py         Request, Route, Responder
│   ├── routes.py          carga rutas de SSM o archivo
│   └── responders.py      EchoResponder, AgentCoreResponder
└── adapters/
    └── discord.py         @menciones, hilos, permisos por rol
deploy/
├── deploy.sh              corre en la EC2 (vía SSM)
├── user-data.sh           bootstrap de la EC2
└── iam-policies.md        roles y policies
.github/workflows/deploy.yml
routes.example.json
```

## 1. Crear el bot en Discord

1. https://discord.com/developers/applications → **New Application** → `ʻIke`.
   En **Bot**, username `ike` (sin ʻokina, fácil de mencionar). Sube un avatar.
2. **Bot** → *Reset Token* → cópialo a `.env` (`DISCORD_TOKEN`).
3. **Bot → Privileged Gateway Intents** → activa **Message Content Intent**
   (sin esto, los mensajes de seguimiento en el hilo llegan vacíos).
4. **OAuth2 → URL Generator** → scope `bot`, permisos: View Channels,
   Send Messages, Create Public Threads, Send Messages in Threads,
   Read Message History. Abre la URL e invítalo al servidor.
5. Dale acceso solo a los canales de soporte.

## 2. Correr local (modo desarrollo)

```bash
cp .env.example .env          # pega DISCORD_TOKEN
uv sync
uv run --env-file .env python -m support_bot discord
```

Sin rutas configuradas responde en cualquier canal con `RESPONDER=echo`.
En Discord: `@ike estado de verificación de Pepito` → abre hilo y responde.

Para probar el ruteo: activa *Developer Mode* en Discord (Ajustes → Avanzado),
click derecho al canal → *Copy ID*, crea `routes.json` a partir de
`routes.example.json` y pon `ROUTES_FILE=routes.json` en `.env`.

Tests:

```bash
uv run pytest
```

## 3. Rutas

Cada clave es `<plataforma>:<channel_id>`. Un canal sin ruta = el bot no responde ahí.

```json
{
  "discord:1290000000000000001": {
    "product": "pay",
    "runtime_arn": "arn:aws:bedrock-agentcore:us-east-1:<PAY>:runtime/pay_support-XXXX",
    "role_arn": "arn:aws:iam::<PAY>:role/support-bot-invoker"
  }
}
```

En producción guárdalas en SSM (`ROUTES_SSM_PARAM=/aloha-support-bot/routes`):
cambiar una ruta no requiere redeploy, solo reiniciar el contenedor.
Si el agente vive en la misma cuenta que el bot, omite `role_arn`.

Agregar un producto = crear su role `support-bot-invoker` + una línea en rutas + el canal.

## 4. Conectar el agente

Cambia `RESPONDER=agentcore`. El contrato con el agente:

- **Payload enviado:** `{"prompt": "...", "requested_by": "discord:<user_id>"}`
- **Respuesta esperada:** `{"result": "<texto>"}`
- **Sesión:** `runtimeSessionId` = id del hilo → el agente conserva contexto.

## 5. Infra (cuenta internal-tools)

1. **ECR:** repo `aloha-support-bot`.
2. **Secrets Manager:** `aloha-support-bot/env` con el contenido del `.env`
   de producción (formato `KEY=valor`, una por línea).
3. **SSM Parameter:** `/aloha-support-bot/routes` con el JSON de rutas.
4. **EC2:** Amazon Linux 2023, `t4g.micro`, subnet pública con IP pública,
   security group **sin reglas de entrada**, tag `App=aloha-support-bot`,
   instance role de `deploy/iam-policies.md`, user data `deploy/user-data.sh`.
   - **IMDSv2 obligatorio con hop limit = 2** (si es 1, el contenedor no
     puede obtener las credenciales del instance role).
   - Acceso por **SSM Session Manager**, sin SSH ni key pair.
5. **GitHub:** OIDC provider + role de deploy (`deploy/iam-policies.md`) y
   secret `AWS_DEPLOY_ROLE_ARN` en el repo.

## 6. Deploy

Push a `main` → build ARM → push a ECR → SSM ejecuta `deploy.sh` en la EC2.

**Rollback:** Actions → *deploy* → *Run workflow* → `image_tag` = SHA anterior.

## 7. Agregar Slack (futuro)

1. `adapters/slack.py` con Slack Bolt en **Socket Mode** (sin endpoint público),
   escuchando `app_mention` y respondiendo en `thread_ts`.
   Debe construir `Request` con `route_key="slack:<channel>"`,
   `session_id="slack-thread-<channel>-<thread_ts>"`, `requested_by="slack:<user>"`.
2. Agregar `"slack"` en `ADAPTERS` (`__main__.py`) y en `PLATFORMS` (`deploy.sh`).
3. Agregar `slack-bolt` a dependencias y `SLACK_BOT_TOKEN` / `SLACK_APP_TOKEN` al secreto.
4. Rutas `"slack:<channel_id>"`.

Mismo core, misma imagen, un contenedor por plataforma.
