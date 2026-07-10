"use client";

import { useState, useRef } from "react";
import StepTracker, { Step, makeSteps } from "@/components/StepTracker";

const EXAMPLE_QUERIES = [
  "How does the Federal Reserve control inflation through interest rates?",
  "What is quantitative easing and how does it affect GDP?",
  "Compare fiscal policy and monetary policy approaches to recession.",
];

export default function Home() {
  const [query, setQuery] = useState("");
  const [steps, setSteps] = useState<Step[]>(makeSteps());
  const [answer, setAnswer] = useState("");
  const [running, setRunning] = useState(false);
  const abortRef = useRef<AbortController | null>(null);

  function resetState() {
    setSteps(makeSteps());
    setAnswer("");
  }

  function markStep(node: string, status: "active" | "done", detail?: string) {
    setSteps((prev) =>
      prev.map((s) =>
        s.node === node ? { ...s, status, detail: detail ?? s.detail } : s
      )
    );
  }

  async function runAgent(q: string) {
    if (running) return;
    resetState();
    setRunning(true);
    abortRef.current = new AbortController();

    try {
      const res = await fetch("/api/agent", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ query: q }),
        signal: abortRef.current.signal,
      });

      const reader = res.body!.getReader();
      const decoder = new TextDecoder();
      let buffer = "";

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;

        buffer += decoder.decode(value, { stream: true });
        const lines = buffer.split("\n");
        buffer = lines.pop() ?? "";

        for (const line of lines) {
          if (!line.startsWith("data: ")) continue;
          const payload = line.slice(6).trim();
          if (payload === "[DONE]") break;

          try {
            const event = JSON.parse(payload);
            if (event.type === "step_start") markStep(event.node, "active");
            if (event.type === "step_done") markStep(event.node, "done", event.detail);
            if (event.type === "answer") setAnswer(event.text);
          } catch {
            // malformed line — skip
          }
        }
      }
    } catch (err: unknown) {
      if (err instanceof Error && err.name !== "AbortError") {
        setAnswer("Error: could not reach the agent backend.");
      }
    } finally {
      setRunning(false);
    }
  }

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (query.trim()) runAgent(query.trim());
  }

  return (
    <div className="flex flex-col h-screen">
      <header
        className="px-6 py-3 border-b"
        style={{ background: "var(--surface)", borderColor: "var(--border)" }}
      >
        <span
          className="text-xs font-mono tracking-widest uppercase"
          style={{ color: "var(--accent)" }}
        >
          Agent Orchestration Demo
        </span>
        <h1 className="text-base font-semibold" style={{ color: "var(--text)" }}>
          LangGraph · Multi-agent routing · MCP server
        </h1>
      </header>

      <div
        className="px-6 py-3 border-b"
        style={{ borderColor: "var(--border)", background: "var(--surface)" }}
      >
        <form onSubmit={handleSubmit} className="flex gap-2">
          <input
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Ask a complex research question…"
            className="flex-1 rounded px-3 py-2 text-sm"
            style={{
              background: "var(--bg)",
              border: "1px solid var(--border)",
              color: "var(--text)",
            }}
          />
          <button
            type="submit"
            disabled={running || !query.trim()}
            className="px-5 py-2 rounded text-sm font-medium transition-opacity"
            style={{
              background: "var(--accent)",
              color: "#fff",
              opacity: running || !query.trim() ? 0.5 : 1,
            }}
          >
            {running ? "Running…" : "Run"}
          </button>
        </form>

        <div className="flex gap-2 mt-2 flex-wrap">
          {EXAMPLE_QUERIES.map((q) => (
            <button
              key={q}
              onClick={() => { setQuery(q); runAgent(q); }}
              className="text-xs px-2 py-1 rounded"
              style={{ border: "1px solid var(--border)", color: "var(--text-2)" }}
            >
              {q.length > 60 ? q.slice(0, 58) + "…" : q}
            </button>
          ))}
        </div>
      </div>

      <div className="flex flex-1 overflow-hidden">
        <div
          className="w-72 shrink-0 border-r overflow-y-auto"
          style={{ background: "var(--surface)", borderColor: "var(--border)" }}
        >
          <StepTracker steps={steps} />
        </div>

        <div className="flex-1 overflow-y-auto p-6">
          {!answer && !running && (
            <p className="text-sm" style={{ color: "var(--text-2)" }}>
              Select an example query or type your own. The agent will classify it,
              optionally decompose it into sub-queries, retrieve context in parallel,
              then synthesize a grounded answer.
            </p>
          )}
          {running && !answer && (
            <p className="text-sm animate-pulse" style={{ color: "var(--text-2)" }}>
              Agent working…
            </p>
          )}
          {answer && (
            <div
              className="prose max-w-none rounded-lg p-5 text-sm leading-relaxed"
              style={{
                background: "var(--surface)",
                border: "1px solid var(--border)",
                color: "var(--text)",
              }}
            >
              <p className="whitespace-pre-wrap">{answer}</p>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
