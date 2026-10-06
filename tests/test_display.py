import asyncio
import json

from ike_bot.adapters.discord import chunks, embed_from_dict, embed_groups
from ike_bot.core.request import Reply, Request, Route
from ike_bot.core.responders import AgentCoreResponder


def _respond_with(body: bytes) -> Reply:
    resp = AgentCoreResponder("us-east-1")

    class Body:
        def read(self):
            return body

    class FakeClient:
        def invoke_agent_runtime(self, **kw):
            return {"response": Body()}

    resp._client = lambda role_arn: FakeClient()
    req = Request("hola", "discord-thread-1-ike-bot", "discord:42", "discord:1",
                  Route(product="pay", runtime_arn="arn:x"))
    return asyncio.run(resp.respond(req))


def test_responder_parsea_display_con_embeds():
    embed = {"title": "Pagos", "fields": [{"name": "a", "value": "b", "inline": False}]}
    body = json.dumps({"result": "tabla en texto",
                       "display": {"text": "Resumen", "embeds": [embed]}}).encode()
    out = _respond_with(body)
    assert out == Reply(text="Resumen", embeds=(embed,))


def test_responder_display_sin_texto_usa_cadena_vacia():
    body = json.dumps({"result": "x", "display": {"embeds": [{"title": "t"}]}}).encode()
    out = _respond_with(body)
    assert out.text == "" and out.embeds == ({"title": "t"},)


def test_responder_sin_display_solo_texto():
    out = _respond_with(json.dumps({"result": "ok"}).encode())
    assert out == Reply(text="ok") and out.embeds == ()


def test_responder_display_invalido_cae_a_result():
    body = json.dumps({"result": "ok", "display": {"embeds": "no-es-lista"}}).encode()
    assert _respond_with(body) == Reply(text="ok")


def test_responder_cuerpo_no_json_es_texto():
    assert _respond_with(b"hola plano") == Reply(text="hola plano")


def test_embed_from_dict_arma_titulo_campos_y_footer():
    e = embed_from_dict({
        "title": "Pagos", "description": "desc", "footer": "pie",
        "fields": [{"name": "n", "value": "v", "inline": True}],
    })
    assert e.title == "Pagos" and e.description == "desc"
    assert e.footer.text == "pie"
    assert len(e.fields) == 1 and e.fields[0].inline is True


def test_embed_from_dict_trunca_valores_largos():
    e = embed_from_dict({"title": "t" * 300, "fields": [
        {"name": "n" * 300, "value": "v" * 1500, "inline": False}]})
    assert len(e.fields[0].value) <= 1024
    assert len(e.fields[0].name) <= 256
    assert len(e.title) <= 256


def test_embed_from_dict_limita_a_25_campos():
    e = embed_from_dict({"title": "t", "fields": [
        {"name": str(i), "value": "v"} for i in range(40)]})
    assert len(e.fields) == 25


def test_embed_from_dict_respeta_total_de_6000():
    e = embed_from_dict({"title": "t", "fields": [
        {"name": "n", "value": "v" * 1024} for _ in range(10)]})
    assert len(e) <= 6000


def test_embed_from_dict_tolera_campos_vacios():
    e = embed_from_dict({"fields": [{"name": "", "value": ""}]})
    assert all(f.name and f.value for f in e.fields)


def test_embed_groups_13_embeds_son_10_y_3():
    groups = embed_groups(list(range(13)))
    assert [len(g) for g in groups] == [10, 3]
    assert embed_groups([]) == []


def test_chunks_sigue_igual():
    assert len(chunks("x" * 2001)) == 2
