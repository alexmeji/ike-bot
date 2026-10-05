import asyncio
import json

import pytest

from support_bot.adapters.discord import chunks
from support_bot.core.request import Request
from support_bot.core.responders import AgentCoreResponder, EchoResponder
from support_bot.core.routes import Router

ROUTES = {
    "discord:1": {"product": "pay", "runtime_arn": "arn:rt/pay", "role_arn": "arn:role/pay"},
    "discord:2": {"product": "axis", "runtime_arn": "arn:rt/axis"},
}


def _req(router, key="discord:1"):
    return Request("estado de Pepito", "discord-thread-123-aloha-support",
                   "discord:42", key, router.resolve(key))


def test_router_resuelve_por_plataforma_y_canal():
    r = Router.from_json(json.dumps(ROUTES))
    assert r.resolve("discord:1").product == "pay"
    assert r.is_allowed("discord:2")
    assert not r.is_allowed("discord:3")
    assert not r.is_allowed("slack:1")


def test_router_exige_prefijo():
    with pytest.raises(ValueError):
        Router.from_json(json.dumps({"123": {"product": "pay"}}))


def test_router_vacio_es_modo_desarrollo():
    r = Router({})
    assert r.dev_mode and r.is_allowed("discord:999")


def test_echo_muestra_producto():
    r = Router.from_json(json.dumps(ROUTES))
    out = asyncio.run(EchoResponder().respond(_req(r)))
    assert "pay" in out and "estado de Pepito" in out


def test_agentcore_sin_ruta_no_invoca():
    resp = AgentCoreResponder("us-east-1")
    out = asyncio.run(resp.respond(_req(Router({}), "discord:9")))
    assert "no está conectado" in out


def test_chunks_respeta_limite_de_discord():
    parts = chunks("x" * 4500)
    assert len(parts) == 3 and all(len(p) <= 2000 for p in parts)
