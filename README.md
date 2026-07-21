# Multi-Agent Orchestration — LangGraph · MCP Server · FastAPI SSE

**LangGraph** state machine with live reasoning visibility: a classifier node routes simple queries
direct to retrieval and complex queries through a decompose node that fans out parallel sub-queries
via LangGraph's `Send` API. Every agent step streams to the browser as SSE events before the final
answer appears. The same tools are also exposed as an **MCP server** over stdio — connectable from
Claude Desktop, Claude Code, or any MCP-compatible client.

**[→ Portfolio demo](https://bganguly.github.io/?open=agent)**

## Using the App

1. Enter a question in the chat input — simple queries route directly to retrieval; complex or multi-part questions decompose into parallel sub-queries.
2. Watch the StepTracker panel as each agent step (classify → decompose → retrieve → synthesize) advances live via SSE — pending / active (⟳) / done (✓) with retrieved detail.
3. The answer streams in after all steps complete.

---

| | |
|---|---|
| **Orchestration** | LangGraph `StateGraph` with conditional edges; `Send` API for parallel fan-out to multiple `retrieve` nodes |
| **Agent graph** | `classify` → (simple) `retrieve` → `synthesize`; (complex) `decompose` → parallel `retrieve` × N → `synthesize` |
| **Tools** | `wikipedia_search` (Wikipedia REST API) · `duckduckgo_search` (DuckDuckGo Instant Answers API) — no API key required |
| **MCP server** | `app/mcp/server.py` exposes `wikipedia_search` and `duckduckgo_search` over stdio using the `mcp` Python SDK; connects to Claude Desktop via `claude_desktop_config.json` |
| **Streaming** | FastAPI `StreamingResponse` emits SSE events: `step_start`, `step_done` (with detail), `answer`; Next.js API route proxies the stream to the browser |
| **Step visibility** | `StepTracker` component renders each node state live: pending → active (⟳) → done (✓) with detail text |
| **LLM** | Anthropic `claude-3-5-haiku-20241022` for classify, decompose, and synthesize nodes |
| **Backend** | FastAPI 0.115 + asyncio; LangGraph `astream_events` with `version="v2"` |
| **Frontend** | Next.js 15 App Router, React 19, TypeScript 5.7, Tailwind CSS; custom SSE consumer hook |
| **Infra** | Docker Compose: `redis:7-alpine` on `:6381` (session state) |

---

## Architecture

```
Browser ──► Next.js :3011 ──► /api/agent ──► FastAPI :8002
              SSE consumer                     LangGraph graph
              StepTracker UI                   classify
              step_start / step_done           ├── retrieve (simple)
              answer text                      └── decompose → retrieve × N (parallel)
                                                              → synthesize
                                               Wikipedia API / DuckDuckGo API

MCP path (Claude Desktop or Claude Code):
  Claude ──stdio──► app/mcp/server.py ──► wikipedia_search / duckduckgo_search
```

---

## Running

```bash
./scripts/deploy.sh      # local [1] or GCP Cloud Run / GKE [2]
./scripts/infra-down.sh  # stop local [1] or delete Cloud Run services [--cloud]
```

Prerequisites for local:
- **Python 3.12+** and **Node 20+**
- Copy `.env.example` → `.env` and fill in `ANTHROPIC_API_KEY`
- Local Redis: `brew install redis && brew services start redis`, then set `REDIS_URL=redis://localhost:6379` in `.env`

Cloud Run deploy requires `gcloud` CLI authenticated (`gcloud auth login`) with a project set.

---

## MCP Server (Claude Desktop)

Add to `~/.claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "agent-tools": {
      "command": "python",
      "args": ["-m", "app.mcp.server"],
      "cwd": "/path/to/agent-orchestration-demo/backend",
      "env": { "ANTHROPIC_API_KEY": "sk-ant-..." }
    }
  }
}
```

Then restart Claude Desktop — the `wikipedia_search` and `duckduckgo_search` tools appear in the tool list.

---

## Quick Test — Local

```bash
# Health
curl http://localhost:8002/health

# Run agent (SSE stream — watch steps arrive)
curl -X POST http://localhost:8002/api/agent/run \
  -H "Content-Type: application/json" \
  -d '{"query": "What is quantitative easing?"}' \
  --no-buffer

# Complex query — triggers decompose + parallel retrieve
curl -X POST http://localhost:8002/api/agent/run \
  -H "Content-Type: application/json" \
  -d '{"query": "Compare fiscal policy and monetary policy approaches to recession."}' \
  --no-buffer
```

---

## Live Services

> **Schedule:** ECS Fargate runs weekdays 8 am – 5 pm PT. Outside those hours the app is offline — [request access](https://bganguly.github.io/?open=agent) for off-hours access.

| Service | Local | Cloud Run |
|---|---|---|
| Next.js app | http://localhost:3011 | https://agent-frontend-77y7e2wykq-uc.a.run.app |
| FastAPI docs | http://localhost:8002/docs | https://agent-backend-77y7e2wykq-uc.a.run.app/docs |
