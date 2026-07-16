import json

from fastapi import APIRouter
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

from app.agents.graph import graph, SPECIALISTS, SYNTHESIS_DOMAINS

router = APIRouter()

HIDDEN_NODES = {"collect"}
KNOWN_NODES = {"plan", "research", "collect", "synthesize", "fact_check", "write"}


def _sse(payload: dict) -> str:
    return f"data: {json.dumps(payload)}\n\n"


class RunRequest(BaseModel):
    query: str


@router.post("/agent/run")
async def run_agent(req: RunRequest) -> StreamingResponse:
    async def event_stream():
        state = {
            "query": req.query,
            "complexity": "simple",
            "specialists": [],
            "specialist": "",
            "domain": "",
            "research_results": [],
            "syntheses": [],
            "answer": "",
            "steps": [],
        }

        async for event in graph.astream_events(state, version="v2"):
            kind = event.get("event")
            name = event.get("name", "")

            if name not in KNOWN_NODES or name in HIDDEN_NODES:
                continue
            if kind not in ("on_chain_start", "on_chain_end"):
                continue

            data = event.get("data", {}) or {}

            if kind == "on_chain_start":
                inp = (data.get("input") or {})

                if name == "plan":
                    yield _sse({"type": "step_start", "node": "plan",
                                "label": "Planner", "layer": 0, "parent": None})

                elif name == "research":
                    sp = inp.get("specialist") or "scientific"
                    yield _sse({"type": "step_start",
                                "node": f"research:{sp}",
                                "label": SPECIALISTS.get(sp, sp),
                                "layer": 1, "parent": "plan"})

                elif name == "synthesize":
                    dom = inp.get("domain") or "clinical"
                    yield _sse({"type": "step_start",
                                "node": f"synthesize:{dom}",
                                "label": SYNTHESIS_DOMAINS.get(dom, dom),
                                "layer": 2, "parent": "research"})

                elif name == "fact_check":
                    yield _sse({"type": "step_start", "node": "fact_check",
                                "label": "Fact Check", "layer": 3, "parent": "synthesize"})

                elif name == "write":
                    complexity = inp.get("complexity", "simple")
                    is_complex = complexity == "complex"
                    yield _sse({"type": "step_start", "node": "write",
                                "label": "Report Writer",
                                "layer": 4 if is_complex else 2,
                                "parent": "fact_check" if is_complex else "research"})

            elif kind == "on_chain_end":
                out = (data.get("output") or {})
                steps = out.get("steps", []) if isinstance(out, dict) else []

                if steps:
                    yield _sse({"type": "step_done", **steps[0]})

                if name == "write":
                    answer = out.get("answer", "") if isinstance(out, dict) else ""
                    if answer:
                        yield _sse({"type": "answer", "text": answer})

        yield "data: [DONE]\n\n"

    return StreamingResponse(event_stream(), media_type="text/event-stream")
