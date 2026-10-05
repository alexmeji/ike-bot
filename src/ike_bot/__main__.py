"""Arranque: python -m ike_bot <plataforma>

    python -m ike_bot discord
    python -m ike_bot slack      # futuro: agregar adapters/slack.py
"""

import logging
import os
import sys

from .core.responders import build_responder
from .core.routes import Router

ADAPTERS = {"discord"}


def main() -> None:
    platform = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("PLATFORM", "discord")
    if platform not in ADAPTERS:
        sys.exit(f"Plataforma desconocida: {platform}. Disponibles: {', '.join(sorted(ADAPTERS))}")

    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )

    router = Router.from_env()
    responder = build_responder(
        os.environ.get("RESPONDER", "echo"),
        region=os.environ.get("AWS_REGION", "us-east-1"),
    )

    if platform == "discord":
        from .adapters import discord as adapter

    adapter.run(router, responder)


if __name__ == "__main__":
    main()
