"""Tipos comunes a todas las plataformas (Discord hoy, Slack después)."""

from dataclasses import dataclass
from typing import Protocol


@dataclass(frozen=True)
class Route:
    product: str                     # "pay", "axis", "supervisor", ...
    runtime_arn: str | None = None   # AgentCore runtime del agente
    role_arn: str | None = None      # role a asumir en la cuenta del producto


@dataclass(frozen=True)
class Request:
    prompt: str
    session_id: str      # un hilo = una sesión del agente ("discord-thread-...")
    requested_by: str    # "discord:<user_id>" / "slack:<user_id>", para auditoría
    route_key: str       # "discord:<channel_id>" / "slack:<channel_id>"
    route: Route | None  # None solo en modo desarrollo (sin rutas configuradas)
    # Nombre visible de quien pregunta; solo para la columna "quién" de la consola.
    requested_by_name: str | None = None


@dataclass(frozen=True)
class Reply:
    """Lo que el agente responde. `embeds` son dicts neutrales a la plataforma
    ({"title", "description"?, "fields": [{"name", "value", "inline"}], "footer"?});
    cada adaptador los dibuja a su manera (Discord embeds, Slack Block Kit)."""

    text: str
    embeds: tuple[dict, ...] = ()


class Responder(Protocol):
    async def respond(self, req: Request) -> Reply: ...
