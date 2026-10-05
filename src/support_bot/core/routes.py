"""Ruteo: canal de chat → agente del producto.

Las rutas se cargan de (en este orden):
  1. ROUTES_SSM_PARAM  → parámetro de SSM Parameter Store con el JSON
  2. ROUTES_FILE       → archivo JSON local
Si no hay ninguna, el bot corre en MODO DESARROLLO: responde en cualquier
canal y sin agente (solo útil con RESPONDER=echo).

Formato (ver routes.example.json):
  { "discord:1290...": {"product": "pay", "runtime_arn": "...", "role_arn": "..."} }
"""

import json
import logging
import os
from pathlib import Path

from .request import Route

log = logging.getLogger(__name__)


class Router:
    def __init__(self, routes: dict[str, Route]):
        self.routes = routes

    @property
    def dev_mode(self) -> bool:
        return not self.routes

    def is_allowed(self, key: str) -> bool:
        return self.dev_mode or key in self.routes

    def resolve(self, key: str) -> Route | None:
        return self.routes.get(key)

    @classmethod
    def from_json(cls, raw: str) -> "Router":
        data = json.loads(raw)
        routes = {}
        for key, value in data.items():
            if ":" not in key:
                raise ValueError(f"Ruta '{key}' sin prefijo de plataforma (ej. 'discord:123')")
            routes[key] = Route(**value)
        return cls(routes)

    @classmethod
    def from_env(cls) -> "Router":
        param = os.environ.get("ROUTES_SSM_PARAM")
        if param:
            import boto3

            raw = boto3.client("ssm").get_parameter(Name=param)["Parameter"]["Value"]
            router = cls.from_json(raw)
            log.info("Rutas cargadas de SSM %s: %s", param, list(router.routes))
            return router

        path = os.environ.get("ROUTES_FILE")
        if path:
            router = cls.from_json(Path(path).read_text())
            log.info("Rutas cargadas de %s: %s", path, list(router.routes))
            return router

        log.warning("Sin rutas configuradas: MODO DESARROLLO (responde en cualquier canal)")
        return cls({})
