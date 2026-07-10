from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.routes import agent

app = FastAPI(title="Agent Orchestration API", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:3011"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(agent.router, prefix="/api")


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}
