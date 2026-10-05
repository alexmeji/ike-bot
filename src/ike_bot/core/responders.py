"""Quién genera la respuesta. Los adaptadores solo conocen `Responder`."""

import asyncio
import json
import logging
import time

from .request import Request, Responder

log = logging.getLogger(__name__)


class EchoResponder:
    """Respuesta de prueba: valida la plataforma de chat de punta a punta."""

    async def respond(self, req: Request) -> str:
        product = req.route.product if req.route else "(modo desarrollo)"
        return (
            "🌺 ʻIke aquí. Recibí tu consulta, pero todavía no estoy conectado al agente.\n"
            f"> {req.prompt}\n"
            f"`producto: {product}` · `sesión: {req.session_id}`"
        )


class AgentCoreResponder:
    """Invoca el runtime de AgentCore del producto, asumiendo el role de su cuenta."""

    def __init__(self, region: str):
        import boto3

        self._boto3 = boto3
        self.region = region
        self._clients: dict[str, tuple[object, float]] = {}  # role_arn -> (client, expira)

    def _client(self, role_arn: str | None):
        if role_arn is None:  # el agente vive en la misma cuenta que el bot
            return self._boto3.client("bedrock-agentcore", region_name=self.region)

        cached = self._clients.get(role_arn)
        if cached and cached[1] - time.time() > 300:
            return cached[0]

        creds = self._boto3.client("sts").assume_role(
            RoleArn=role_arn, RoleSessionName="ike-bot"
        )["Credentials"]
        client = self._boto3.client(
            "bedrock-agentcore",
            region_name=self.region,
            aws_access_key_id=creds["AccessKeyId"],
            aws_secret_access_key=creds["SecretAccessKey"],
            aws_session_token=creds["SessionToken"],
        )
        self._clients[role_arn] = (client, creds["Expiration"].timestamp())
        return client

    def _invoke(self, req: Request) -> str:
        route = req.route
        resp = self._client(route.role_arn).invoke_agent_runtime(
            agentRuntimeArn=route.runtime_arn,
            runtimeSessionId=req.session_id,
            payload=json.dumps(
                {
                    "prompt": req.prompt,
                    "requested_by": req.requested_by,
                    # The agent behind one runtime can serve several products;
                    # the channel's route is what says which one this is.
                    "product": route.product,
                }
            ).encode(),
        )
        body = resp["response"].read()
        try:
            data = json.loads(body)
        except json.JSONDecodeError:
            return body.decode()
        # Contrato con el agente: {"result": "<texto>"}
        return data.get("result", str(data)) if isinstance(data, dict) else str(data)

    async def respond(self, req: Request) -> str:
        if req.route is None or not req.route.runtime_arn:
            return "Este canal no está conectado a ningún agente."
        log.info("invoke product=%s by=%s", req.route.product, req.requested_by)
        return await asyncio.to_thread(self._invoke, req)


def build_responder(name: str, region: str) -> Responder:
    if name == "echo":
        return EchoResponder()
    if name == "agentcore":
        return AgentCoreResponder(region)
    raise ValueError(f"RESPONDER desconocido: {name} (usa 'echo' o 'agentcore')")
