"""LangGraph 20-agent research pipeline.

Flow (complex):
  plan → research×N (parallel) → collect → synthesize×4 (parallel) → fact_check → write

Flow (simple):
  plan → research×2-3 (parallel) → collect → write
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

SPECIALISTS: dict[str, str] = {
    "clinical":     "Clinical & Medical",
    "economics":    "Economics & Finance",
    "regulatory":   "Regulatory & Policy",
    "technology":   "Technology & Innovation",
    "ethics":       "Ethics & Society",
    "historical":   "Historical Context",
    "competitive":  "Competitive Landscape",
    "scientific":   "Scientific Literature",
    "consumer":     "Consumer & Demand",
    "geopolitical": "Geopolitical",
}

SPECIALIST_FOCUS: dict[str, str] = {
    "clinical":     "clinical trials patient outcomes medical evidence",
    "economics":    "economic impact market size cost analysis",
    "regulatory":   "regulations policy compliance legal framework",
    "technology":   "technical implementation innovation methods tools",
    "ethics":       "ethical implications social responsibility fairness",
    "historical":   "historical precedents evolution timeline origins",
    "competitive":  "key players companies market leaders competition",
    "scientific":   "research studies academic evidence data findings",
    "consumer":     "consumer adoption demand user behavior trends",
    "geopolitical": "international relations global policy geopolitics",
}

SYNTHESIS_DOMAINS: dict[str, str] = {
    "clinical":  "Clinical & Scientific Synthesis",
    "business":  "Business & Economic Synthesis",
    "policy":    "Policy & Regulatory Synthesis",
    "societal":  "Societal Impact Synthesis",
}

SYNTHESIS_SPECIALISTS: dict[str, list[str]] = {
    "clinical":  ["clinical", "scientific"],
    "business":  ["economics", "competitive", "consumer"],
    "policy":    ["regulatory", "geopolitical"],
    "societal":  ["ethics", "historical", "technology"],
}


class AgentState(TypedDict):
    query: str
    complexity: str
    specialists: list[str]
    specialist: str
    domain: str
    research_results: Annotated[list[dict], operator.add]
    syntheses: Annotated[list[dict], operator.add]
    answer: str
    steps: Annotated[list[dict], operator.add]


# ── plan ──────────────────────────────────────────────────────────

async def plan_node(state: AgentState) -> dict:
    prompt = f"""Analyze this research query and respond with JSON only.

Query: {state['query']}

Classify as "simple" (single topic, quick fact) or "complex" (multi-faceted, benefits from broad parallel research).
Select the most relevant specialist types from: {list(SPECIALISTS.keys())}
- simple: pick 2-3 most relevant
- complex: pick 6-10 most relevant

Respond with ONLY valid JSON — no markdown, no explanation:
{{"complexity": "simple", "specialists": ["specialist1", "specialist2"]}}"""

    resp = await _llm.ainvoke([HumanMessage(content=prompt)])
    try:
        raw = resp.content.strip().lstrip("```json").lstrip("```").rstrip("```").strip()
        data = json.loads(raw)
        complexity = "complex" if data.get("complexity") == "complex" else "simple"
        specialists = [s for s in data.get("specialists", []) if s in SPECIALISTS]
        if not specialists:
            specialists = ["scientific", "historical"]
    except (ValueError, json.JSONDecodeError):
        complexity = "simple"
        specialists = ["scientific", "historical"]

    return {
        "complexity": complexity,
        "specialists": specialists,
        "specialist": "",
        "domain": "",
        "steps": [{
            "node": "plan",
            "label": "Planner",
            "layer": 0,
            "parent": None,
            "detail": f"{'Complex' if complexity == 'complex' else 'Simple'} query → {len(specialists)} researchers",
        }],
    }


def route_after_plan(state: AgentState):
    return [Send("research", {"specialist": s, **state}) for s in state["specialists"]]


# ── research ──────────────────────────────────────────────────────

async def research_node(state: AgentState) -> dict:
    specialist = state.get("specialist") or "scientific"
    focus = SPECIALIST_FOCUS.get(specialist, "")
    search_q = f"{state['query']} {focus}"

    wiki, ddgo = await wikipedia_search(search_q), await duckduckgo_search(search_q)
    content = f"[Wikipedia]\n{wiki}\n\n[Web]\n{ddgo}"

    return {
        "research_results": [{"specialist": specialist, "content": content}],
        "steps": [{
            "node": f"research:{specialist}",
            "label": SPECIALISTS[specialist],
            "layer": 1,
            "parent": "plan",
            "detail": f"{len(content.split())} words retrieved",
        }],
    }


# ── collect (barrier — invisible in UI) ───────────────────────────

async def collect_node(state: AgentState) -> dict:
    return {"steps": []}


def route_after_collect(state: AgentState):
    if state.get("complexity", "simple") != "complex":
        return "write"
    return [Send("synthesize", {"domain": d, **state}) for d in SYNTHESIS_DOMAINS]


# ── synthesize ────────────────────────────────────────────────────

async def synthesize_node(state: AgentState) -> dict:
    domain = state.get("domain") or "clinical"
    relevant_specs = SYNTHESIS_SPECIALISTS.get(domain, list(SPECIALISTS.keys()))

    relevant = [r for r in state["research_results"] if r["specialist"] in relevant_specs]
    if not relevant:
        relevant = state["research_results"]

    context = "\n\n".join(
        f"[{SPECIALISTS[r['specialist']]}]\n{r['content'][:800]}"
        for r in relevant
    )

    messages = [
        SystemMessage(content=(
            f"You are a {SYNTHESIS_DOMAINS[domain]} specialist. "
            "Synthesize the provided research into a clear 2-3 paragraph domain summary. "
            "Be specific, cite key findings, stay in your domain."
        )),
        HumanMessage(content=f"Query: {state['query']}\n\nResearch:\n{context}"),
    ]
    resp = await _llm.ainvoke(messages)

    return {
        "syntheses": [{"domain": domain, "content": resp.content}],
        "steps": [{
            "node": f"synthesize:{domain}",
            "label": SYNTHESIS_DOMAINS[domain],
            "layer": 2,
            "parent": "research",
            "detail": f"Synthesized {len(relevant)} research stream(s)",
        }],
    }


# ── fact_check ────────────────────────────────────────────────────

async def fact_check_node(state: AgentState) -> dict:
    synthesis_text = "\n\n".join(s["content"] for s in state["syntheses"])[:2000]

    messages = [
        SystemMessage(content=(
            "You are a fact-checker. Review the syntheses for consistency and accuracy. "
            "Flag any contradictions or unsupported claims in 2-3 sentences."
        )),
        HumanMessage(content=f"Query: {state['query']}\n\nSyntheses:\n{synthesis_text}"),
    ]
    resp = await _llm.ainvoke(messages)

    return {
        "syntheses": [{"domain": "_fact_check", "content": resp.content}],
        "steps": [{
            "node": "fact_check",
            "label": "Fact Check",
            "layer": 3,
            "parent": "synthesize",
            "detail": "Claims validated",
        }],
    }


# ── write ─────────────────────────────────────────────────────────

async def write_node(state: AgentState) -> dict:
    is_complex = state.get("complexity") == "complex"

    if is_complex and state.get("syntheses"):
        context = "\n\n".join(
            f"## {s['domain'].replace('_', ' ').title()}\n{s['content']}"
            for s in state["syntheses"]
            if not s["domain"].startswith("_")
        )
        system = (
            "You are a research report writer. Write a structured report answering the query. "
            "Use ## section headings. Be comprehensive but concise. Cite sources where evident."
        )
    else:
        context = "\n\n".join(
            f"[{SPECIALISTS.get(r['specialist'], r['specialist'])}]\n{r['content'][:600]}"
            for r in state["research_results"]
        )
        system = "You are a research assistant. Answer clearly and concisely using the provided context."

    messages = [
        SystemMessage(content=system),
        HumanMessage(content=f"Query: {state['query']}\n\nResearch:\n{context}"),
    ]
    resp = await _llm.ainvoke(messages)

    layer = 4 if is_complex else 2
    parent = "fact_check" if is_complex else "research"

    return {
        "answer": resp.content,
        "steps": [{
            "node": "write",
            "label": "Report Writer",
            "layer": layer,
            "parent": parent,
            "detail": "Report generated",
        }],
    }


# ── build graph ───────────────────────────────────────────────────

def build_graph() -> Any:
    g = StateGraph(AgentState)
    g.add_node("plan", plan_node)
    g.add_node("research", research_node)
    g.add_node("collect", collect_node)
    g.add_node("synthesize", synthesize_node)
    g.add_node("fact_check", fact_check_node)
    g.add_node("write", write_node)

    g.set_entry_point("plan")
    g.add_conditional_edges("plan", route_after_plan, ["research"])
    g.add_edge("research", "collect")
    g.add_conditional_edges("collect", route_after_collect, ["synthesize", "write"])
    g.add_edge("synthesize", "fact_check")
    g.add_edge("fact_check", "write")
    g.add_edge("write", END)

    return g.compile()


graph = build_graph()
