import asyncio
import json

import pytest

from ike_bot.adapters.discord import chunks
from ike_bot.core.request import Request, Route
from ike_bot.core.responders import AgentCoreResponder, EchoResponder
from ike_bot.core.routes import Router

ROUTES = {
    "discord:1": {"product": "pay", "runtime_arn": "arn:rt/pay", "role_arn": "arn:role/pay"},
    "discord:2": {"product": "axis", "runtime_arn": "arn:rt/axis"},
}


def _req(router, key="discord:1"):
    return Request("estado de Pepito", "discord-thread-123-ike-bot",
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
    assert "pay" in out.text and "estado de Pepito" in out.text


def test_agentcore_sin_ruta_no_invoca():
    resp = AgentCoreResponder("us-east-1")
    out = asyncio.run(resp.respond(_req(Router({}), "discord:9")))
    assert "no está conectado" in out.text


def test_chunks_respeta_limite_de_discord():
    parts = chunks("x" * 4500)
    assert len(parts) == 3 and all(len(p) <= 2000 for p in parts)


def test_agentcore_manda_el_producto_de_la_ruta():
    resp = AgentCoreResponder("us-east-1")
    sent = {}

    class FakeClient:
        def invoke_agent_runtime(self, **kw):
            sent.update(kw)

            class Body:
                def read(self):
                    return json.dumps({"result": "ok"}).encode()

            return {"response": Body()}

    resp._client = lambda role_arn: FakeClient()
    req = Request(
        prompt="hola", session_id="discord-thread-1-ike-bot",
        requested_by="discord:42", route_key="discord:1",
        route=Route(product="pay", runtime_arn="arn:x", role_arn=None),
    )
    assert asyncio.run(resp.respond(req)).text == "ok"
    assert json.loads(sent["payload"]) == {
        "prompt": "hola", "requested_by": "discord:42", "product": "pay",
    }


def _payload_enviado(**extra):
    resp = AgentCoreResponder("us-east-1")
    sent = {}

    class FakeClient:
        def invoke_agent_runtime(self, **kw):
            sent.update(kw)

            class Body:
                def read(self):
                    return json.dumps({"result": "ok"}).encode()

            return {"response": Body()}

    resp._client = lambda role_arn: FakeClient()
    req = Request(
        prompt="hola", session_id="discord-thread-1-ike-bot",
        requested_by="discord:42", route_key="discord:1",
        route=Route(product="pay", runtime_arn="arn:x", role_arn=None), **extra,
    )
    asyncio.run(resp.respond(req))
    return json.loads(sent["payload"])


def test_agentcore_incluye_el_nombre_visible_sin_espacios():
    p = _payload_enviado(requested_by_name="  Alex  ")
    assert p["requested_by_name"] == "Alex"
    assert p["requested_by"] == "discord:42"


@pytest.mark.parametrize("name", [None, "", "   "])
def test_agentcore_omite_el_nombre_si_no_hay(name):
    assert "requested_by_name" not in _payload_enviado(requested_by_name=name)
