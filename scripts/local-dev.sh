#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BACKEND="$ROOT/backend"
FRONTEND="$ROOT/frontend"

# ── env ──────────────────────────────────────────────────────────
if [ ! -f "$ROOT/.env" ]; then
  cp "$ROOT/.env.example" "$ROOT/.env"
  echo "Created .env from .env.example — fill in ANTHROPIC_API_KEY."
  exit 1
fi

# ── infra ────────────────────────────────────────────────────────
echo "Starting redis..."
docker compose -f "$ROOT/docker-compose.yml" up -d

# ── backend ──────────────────────────────────────────────────────
cd "$BACKEND"
[ -d .venv ] || python3 -m venv .venv
source .venv/bin/activate
pip install -q -r requirements.txt

cp "$ROOT/.env" "$BACKEND/.env" 2>/dev/null || true

uvicorn app.main:app --host 0.0.0.0 --port 8002 --reload &
BACKEND_PID=$!
echo "Backend started (pid $BACKEND_PID) → http://localhost:8002"

# ── frontend ─────────────────────────────────────────────────────
cd "$FRONTEND"
[ -d node_modules ] || npm install

grep -E '^(ANTHROPIC|NVIDIA|BACKEND)' "$ROOT/.env" > "$FRONTEND/.env.local" 2>/dev/null || true

npm run dev &
FRONTEND_PID=$!
echo "Frontend started (pid $FRONTEND_PID) → http://localhost:3011"

echo ""
echo "  Backend  http://localhost:8002/docs"
echo "  App      http://localhost:3011"
echo ""
echo "MCP server (for Claude Desktop):"
echo "  cd $BACKEND && source .venv/bin/activate && python -m app.mcp.server"
echo ""
echo "Press Ctrl+C to stop."

cleanup() {
  echo "Stopping..."
  kill "$BACKEND_PID" "$FRONTEND_PID" 2>/dev/null || true
  docker compose -f "$ROOT/docker-compose.yml" down
}
trap cleanup EXIT INT TERM

wait "$BACKEND_PID" "$FRONTEND_PID"
