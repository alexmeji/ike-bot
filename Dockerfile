FROM python:3.12-slim

COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy PYTHONUNBUFFERED=1

WORKDIR /app
COPY pyproject.toml README.md ./
COPY src ./src
RUN uv pip install --system --no-cache .

RUN useradd --create-home bot
USER bot

# La plataforma se pasa como argumento: docker run ... <imagen> discord
ENTRYPOINT ["python", "-m", "support_bot"]
CMD ["discord"]
