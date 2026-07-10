import json

from fastapi import APIRouter
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

from app.agents.graph import graph

router = APIRouter()


class RunRequest(BaseModel):
    query: str


@router.post("/agent/run")
async def run_agent(req: RunRequest) -> StreamingResponse:
    async def event_stream():
        state = {
            "query": req.query,
            "sub_queries": [],
            "retrieved": [],
            "steps": [],
            "answer": "",
        }

        async for event in graph.astream_events(state, version="v2"):
            kind = event.get("event")
            name = event.get("name", "")

            if kind == "on_chain_start" and name in ("classify", "decompose", "retrieve", "synthesize"):
                yield f"data: {json.dumps({'type': 'step_start', 'node': name})}\n\n"

            elif kind == "on_chain_end" and name in ("classify", "decompose", "retrieve", "synthesize"):
                output = event.get("data", {}).get("output", {})
                steps = output.get("steps", [])
                detail = steps[0]["detail"] if steps else ""
                yield f"data: {json.dumps({'type': 'step_done', 'node': name, 'detail': detail})}\n\n"

                if name == "synthesize":
                    answer = output.get("answer", "")
                    yield f"data: {json.dumps({'type': 'answer', 'text': answer})}\n\n"

        yield "data: [DONE]\n\n"

    return StreamingResponse(event_stream(), media_type="text/event-stream")
