"""MCP server exposing agent tools over stdio.

Run standalone:
  python -m app.mcp.server

Claude Desktop config (~/.claude/claude_desktop_config.json):
  {
    "mcpServers": {
      "agent-tools": {
        "command": "python",
        "args": ["-m", "app.mcp.server"],
        "cwd": "/path/to/agent-orchestration-demo/backend"
      }
    }
  }
"""

import asyncio
import json

from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp.types import CallToolResult, TextContent, Tool

from app.agents.tools import wikipedia_search, duckduckgo_search

server = Server("agent-tools")


@server.list_tools()
async def list_tools() -> list[Tool]:
    return [
        Tool(
            name="wikipedia_search",
            description="Fetch a Wikipedia article summary for a given topic.",
            inputSchema={
                "type": "object",
                "properties": {"query": {"type": "string", "description": "Topic to look up"}},
                "required": ["query"],
            },
        ),
        Tool(
            name="duckduckgo_search",
            description="Search the web via DuckDuckGo Instant Answers API.",
            inputSchema={
                "type": "object",
                "properties": {"query": {"type": "string", "description": "Search query"}},
                "required": ["query"],
            },
        ),
    ]


@server.call_tool()
async def call_tool(name: str, arguments: dict) -> list[TextContent]:
    query = arguments.get("query", "")
    if name == "wikipedia_search":
        result = await wikipedia_search(query)
    elif name == "duckduckgo_search":
        result = await duckduckgo_search(query)
    else:
        result = f"Unknown tool: {name}"
    return [TextContent(type="text", text=result)]


async def main() -> None:
    async with stdio_server() as (read_stream, write_stream):
        await server.run(read_stream, write_stream, server.create_initialization_options())


if __name__ == "__main__":
    asyncio.run(main())
