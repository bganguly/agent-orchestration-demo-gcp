"""LangGraph multi-agent orchestration graph.

Flow:
  classify → simple path  → retrieve → synthesize → END
           → complex path → decompose → retrieve (parallel via Send) → synthesize → END
"""

import json
import operator
from typing import Annotated, Any

from langchain_anthropic import ChatAnthropic
from langchain_core.messages import HumanMessage, SystemMessage
from langgraph.graph import END, StateGraph
from langgraph.types import Send
from typing_extensions import TypedDict

from app.agents.tools import wikipedia_search, duckduckgo_search
from app.config import settings

_llm = ChatAnthropic(
    model="claude-3-5-haiku-20241022",
    anthropic_api_key=settings.anthropic_api_key,
    max_tokens=1024,
)


class AgentState(TypedDict):
    query: str
    sub_queries: list[str]
    retrieved: Annotated[list[str], operator.add]
    steps: Annotated[list[dict[str, str]], operator.add]
    answer: str


# ── classify ─────────────────────────────────────────────────────

async def classify_node(state: AgentState) -> dict:
    prompt = f"""Decide if this query requires multiple independent lookups (complex) or a single lookup (simple).
Reply with exactly one word: simple or complex.

Query: {state['query']}"""
    resp = await _llm.ainvoke([HumanMessage(content=prompt)])
    decision = resp.content.strip().lower()
    complexity = "complex" if "complex" in decision else "simple"
    return {
        "steps": [{"node": "classify", "detail": f"Query classified as {complexity}"}],
        "sub_queries": [state["query"]] if complexity == "simple" else [],
    }


def route_after_classify(state: AgentState):
    if state["sub_queries"]:
        return [Send("retrieve", {"query": state["sub_queries"][0], **state})]
    return "decompose"


# ── decompose ────────────────────────────────────────────────────

async def decompose_node(state: AgentState) -> dict:
    prompt = f"""Break this query into 2-3 focused sub-queries for parallel research.
Return a JSON array of strings. Example: ["sub-query 1", "sub-query 2"]

Query: {state['query']}"""
    resp = await _llm.ainvoke([HumanMessage(content=prompt)])
    try:
        sub_queries = json.loads(resp.content.strip())
        if not isinstance(sub_queries, list):
            raise ValueError
    except (ValueError, json.JSONDecodeError):
        sub_queries = [state["query"]]

    return {
        "sub_queries": sub_queries,
        "steps": [{"node": "decompose", "detail": f"Split into {len(sub_queries)} sub-queries: {sub_queries}"}],
    }


def route_after_decompose(state: AgentState):
    return [Send("retrieve", {"query": sq, **state}) for sq in state["sub_queries"]]


# ── retrieve ─────────────────────────────────────────────────────

async def retrieve_node(state: AgentState) -> dict:
    query = state["query"]
    wiki = await wikipedia_search(query)
    ddgo = await duckduckgo_search(query)
    result = f"[Wikipedia — {query}]\n{wiki}\n\n[Web — {query}]\n{ddgo}"
    return {
        "retrieved": [result],
        "steps": [{"node": "retrieve", "detail": f"Retrieved context for: {query}"}],
    }


# ── synthesize ───────────────────────────────────────────────────

async def synthesize_node(state: AgentState) -> dict:
    context = "\n\n---\n\n".join(state["retrieved"])
    messages = [
        SystemMessage(
            content="You are a helpful research assistant. Answer the question using only the context provided. "
                    "Be concise and cite which source you used."
        ),
        HumanMessage(
            content=f"Context:\n{context}\n\nQuestion: {state['query']}"
        ),
    ]
    resp = await _llm.ainvoke(messages)
    return {
        "answer": resp.content,
        "steps": [{"node": "synthesize", "detail": "Generated final answer"}],
    }


# ── build graph ──────────────────────────────────────────────────

def build_graph() -> Any:
    g = StateGraph(AgentState)
    g.add_node("classify", classify_node)
    g.add_node("decompose", decompose_node)
    g.add_node("retrieve", retrieve_node)
    g.add_node("synthesize", synthesize_node)

    g.set_entry_point("classify")
    g.add_conditional_edges("classify", route_after_classify, ["retrieve", "decompose"])
    g.add_conditional_edges("decompose", route_after_decompose, ["retrieve"])
    g.add_edge("retrieve", "synthesize")
    g.add_edge("synthesize", END)

    return g.compile()


graph = build_graph()
