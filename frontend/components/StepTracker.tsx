"use client";

export type StepStatus = "pending" | "active" | "done";

export interface Step {
  node: string;
  label: string;
  status: StepStatus;
  detail?: string;
}

const NODE_LABELS: Record<string, string> = {
  classify: "Classify query",
  decompose: "Decompose into sub-queries",
  retrieve: "Retrieve context",
  synthesize: "Synthesize answer",
};

export function makeSteps(): Step[] {
  return ["classify", "decompose", "retrieve", "synthesize"].map((node) => ({
    node,
    label: NODE_LABELS[node],
    status: "pending",
  }));
}

export default function StepTracker({ steps }: { steps: Step[] }) {
  return (
    <div className="flex flex-col gap-2 p-5">
      <span
        className="text-xs font-mono uppercase tracking-widest mb-2"
        style={{ color: "var(--text-2)" }}
      >
        Agent Steps
      </span>
      {steps.map((step) => (
        <div
          key={step.node}
          className="flex items-start gap-3 rounded-md px-3 py-2.5"
          style={{
            background:
              step.status === "done"
                ? "var(--done-bg)"
                : step.status === "active"
                ? "var(--active-bg)"
                : "var(--pending-bg)",
            border: "1px solid var(--border)",
          }}
        >
          <span className="mt-0.5 text-base leading-none">
            {step.status === "done" ? "✓" : step.status === "active" ? "⟳" : "○"}
          </span>
          <div>
            <p
              className="text-sm font-medium"
              style={{
                color:
                  step.status === "done"
                    ? "var(--done)"
                    : step.status === "active"
                    ? "var(--active)"
                    : "var(--text-2)",
              }}
            >
              {step.label}
            </p>
            {step.detail && (
              <p className="text-xs mt-0.5" style={{ color: "var(--text-2)" }}>
                {step.detail}
              </p>
            )}
          </div>
        </div>
      ))}
    </div>
  );
}
