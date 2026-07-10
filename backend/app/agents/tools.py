"""Tools available to agent nodes — all pure functions, no side effects."""

import httpx

WIKIPEDIA_SUMMARY = "https://en.wikipedia.org/api/rest_v1/page/summary/{slug}"
DDGO_SEARCH = "https://api.duckduckgo.com/?q={q}&format=json&no_html=1&skip_disambig=1"


async def wikipedia_search(query: str) -> str:
    slug = query.strip().replace(" ", "_")
    async with httpx.AsyncClient(timeout=10) as client:
        r = await client.get(WIKIPEDIA_SUMMARY.format(slug=slug))
        if r.status_code == 200:
            data = r.json()
            title = data.get("title", query)
            extract = data.get("extract", "No summary available.")
            return f"**{title}**\n{extract}"
        return f"Wikipedia: no article found for '{query}'"


async def duckduckgo_search(query: str) -> str:
    async with httpx.AsyncClient(timeout=10) as client:
        r = await client.get(DDGO_SEARCH.format(q=httpx.URL(query)))
        if r.status_code == 200:
            data = r.json()
            abstract = data.get("Abstract", "")
            related = [t.get("Text", "") for t in data.get("RelatedTopics", [])[:3] if "Text" in t]
            parts = [abstract] + related
            result = "\n".join(p for p in parts if p)
            return result or f"No DuckDuckGo results for '{query}'"
        return f"DuckDuckGo search failed for '{query}'"


TOOL_MAP: dict[str, object] = {
    "wikipedia_search": wikipedia_search,
    "duckduckgo_search": duckduckgo_search,
}
