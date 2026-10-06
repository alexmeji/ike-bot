"""Adaptador de Discord: responde a @menciones y sigue la conversación en un hilo."""

import logging
import os

import discord

from ..core.request import Reply, Request, Responder
from ..core.routes import Router

log = logging.getLogger(__name__)

DISCORD_LIMIT = 2000
EMBEDS_PER_MESSAGE = 10
EMBED_COLOR = discord.Color.from_rgb(255, 107, 53)  # naranja Aloha
_EMPTY = "\u200b"  # Discord rechaza nombres/valores vacíos


def _ids(name: str) -> frozenset[int]:
    raw = os.environ.get(name, "")
    return frozenset(int(x) for x in raw.replace(" ", "").split(",") if x)


def chunks(text: str, size: int = DISCORD_LIMIT) -> list[str]:
    return [text[i : i + size] for i in range(0, len(text), size)] or ["(sin respuesta)"]


def _clip(value, limit: int) -> str:
    text = str(value if value is not None else "")
    return text if len(text) <= limit else text[: limit - 1] + "…"


def embed_from_dict(d: dict) -> discord.Embed:
    """Dict neutral del agente -> discord.Embed, recortado a los límites de Discord."""
    embed = discord.Embed(
        title=_clip(d.get("title"), 256) or None,
        description=_clip(d.get("description"), 4096) or None,
        color=EMBED_COLOR,
    )
    fields = d.get("fields")
    for f in (fields if isinstance(fields, list) else [])[:25]:
        if not isinstance(f, dict):
            continue
        embed.add_field(
            name=_clip(f.get("name"), 256) or _EMPTY,
            value=_clip(f.get("value"), 1024) or _EMPTY,
            inline=bool(f.get("inline", False)),
        )
    if d.get("footer"):
        embed.set_footer(text=_clip(d["footer"], 2048))
    while len(embed) > 6000 and embed.fields:  # tope total por embed
        embed.remove_field(len(embed.fields) - 1)
    return embed


def embed_groups(embeds: list, size: int = EMBEDS_PER_MESSAGE) -> list[list]:
    """Discord admite hasta 10 embeds por mensaje."""
    return [embeds[i : i + size] for i in range(0, len(embeds), size)]


class DiscordAdapter(discord.Client):
    def __init__(self, router: Router, responder: Responder):
        intents = discord.Intents.default()
        # Para leer los mensajes de seguimiento dentro del hilo (sin @).
        # Activar "Message Content Intent" en el Developer Portal.
        intents.message_content = True
        super().__init__(intents=intents)
        self.router = router
        self.responder = responder
        self.allowed_role_ids = _ids("DISCORD_ALLOWED_ROLE_IDS")

    async def on_ready(self):
        log.info("Discord conectado como %s (id=%s)", self.user, self.user.id)

    # --- filtros -----------------------------------------------------------

    def _is_bot_thread(self, channel) -> bool:
        return isinstance(channel, discord.Thread) and channel.owner_id == self.user.id

    @staticmethod
    def _base_channel_id(channel) -> int:
        return channel.parent_id if isinstance(channel, discord.Thread) else channel.id

    def _user_allowed(self, member) -> bool:
        if not self.allowed_role_ids:
            return True
        return any(r.id in self.allowed_role_ids for r in getattr(member, "roles", []))

    def _clean_prompt(self, msg: discord.Message) -> str:
        text = msg.content
        for mention in (f"<@{self.user.id}>", f"<@!{self.user.id}>"):
            text = text.replace(mention, "")
        return text.strip()

    # --- evento principal --------------------------------------------------

    async def on_message(self, msg: discord.Message):
        if msg.author.bot or msg.guild is None:
            return  # ignora bots y DMs

        mentioned = self.user in msg.mentions
        in_thread = self._is_bot_thread(msg.channel)
        if not (mentioned or in_thread):
            return

        route_key = f"discord:{self._base_channel_id(msg.channel)}"
        if not self.router.is_allowed(route_key):
            return  # canal sin ruta: silencio
        if not self._user_allowed(msg.author):
            await msg.reply("No tienes acceso a este bot.", mention_author=False)
            return

        prompt = self._clean_prompt(msg)
        if not prompt:
            await msg.reply(
                "¿En qué te ayudo? Ej: `@ike estado de verificación de Pepito`",
                mention_author=False,
            )
            return

        thread = msg.channel if in_thread else await msg.create_thread(
            name=prompt[:90], auto_archive_duration=60
        )

        req = Request(
            prompt=prompt,
            session_id=f"discord-thread-{thread.id}-ike-bot",  # AgentCore pide >= 33 chars
            requested_by=f"discord:{msg.author.id}",
            route_key=route_key,
            route=self.router.resolve(route_key),
        )
        log.info("consulta by=%s route=%s thread=%s", req.requested_by, route_key, thread.id)

        try:
            async with thread.typing():
                reply = await self.responder.respond(req)
        except Exception:
            log.exception("Error generando respuesta")
            reply = Reply(text="⚠️ Tuve un problema procesando la consulta. Intenta de nuevo.")

        # Sin embeds: solo texto. Con embeds: el texto (si hay) y luego las tablas.
        if reply.text or not reply.embeds:
            for part in chunks(reply.text):
                await thread.send(part)
        for group in embed_groups([embed_from_dict(e) for e in reply.embeds]):
            await thread.send(embeds=group)


def run(router: Router, responder: Responder) -> None:
    token = os.environ.get("DISCORD_TOKEN")
    if not token:
        raise RuntimeError("Falta DISCORD_TOKEN")
    DiscordAdapter(router, responder).run(token, log_handler=None)
