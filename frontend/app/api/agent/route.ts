export async function POST(req: Request) {
  const { query } = await req.json();
  const backendUrl = process.env.BACKEND_URL ?? "http://localhost:8002";

  const res = await fetch(`${backendUrl}/api/agent/run`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ query }),
  });

  return new Response(res.body, {
    headers: {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      Connection: "keep-alive",
    },
  });
}
