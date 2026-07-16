"use client";

import { memo, useCallback, useEffect } from "react";
import {
  ReactFlow,
  Node,
  Edge,
  Handle,
  Position,
  MarkerType,
  Background,
  Controls,
  useNodesState,
  useEdgesState,
  useReactFlow,
} from "@xyflow/react";
import "@xyflow/react/dist/style.css";

export type NodeStatus = "running" | "done";

export interface FlowNode {
  id: string;
  label: string;
  layer: number;
  parent: string | null;
  status: NodeStatus;
  detail?: string;
}

// ── Layout constants ────────────────────────────────────────────
const LAYER_Y: Record<number, number> = { 0: 30, 1: 180, 2: 330, 3: 450, 4: 570 };
const NODE_W = 160;
const NODE_H = 56;
const CANVAS_W = 1100;
const MAX_PER_LAYER: Record<number, number> = { 0: 1, 1: 10, 2: 4, 3: 1, 4: 1 };

function nodeX(layer: number, idx: number): number {
  const slots = MAX_PER_LAYER[layer] ?? 4;
  const step = CANVAS_W / (slots + 1);
  return step * (idx + 1) - NODE_W / 2;
}

// ── Custom node component ───────────────────────────────────────
const AgentNodeComponent = memo(function AgentNodeComponent({
  data,
}: {
  data: { label: string; status: NodeStatus; detail?: string };
}) {
  const isRunning = data.status === "running";
  const isDone = data.status === "done";

  return (
    <div
      style={{
        width: NODE_W,
        minHeight: NODE_H,
        borderRadius: 8,
        border: `1.5px solid ${isDone ? "var(--done)" : isRunning ? "var(--active)" : "var(--border)"}`,
        background: isDone ? "var(--done-bg)" : isRunning ? "var(--active-bg)" : "var(--surface)",
        padding: "8px 10px",
        display: "flex",
        flexDirection: "column",
        gap: 3,
        boxShadow: isRunning ? "0 0 0 3px color-mix(in srgb, var(--active) 20%, transparent)" : undefined,
        transition: "all 0.25s ease",
        animation: isRunning ? "nodePulse 1.4s ease-in-out infinite" : undefined,
      }}
    >
      <Handle type="target" position={Position.Top} style={{ background: "var(--border)", width: 6, height: 6 }} />
      <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
        <span style={{ fontSize: 11, lineHeight: 1 }}>
          {isDone ? "✓" : isRunning ? "⟳" : "○"}
        </span>
        <span
          style={{
            fontSize: 11,
            fontWeight: 600,
            color: isDone ? "var(--done)" : isRunning ? "var(--active)" : "var(--text-2)",
            lineHeight: 1.3,
          }}
        >
          {data.label}
        </span>
      </div>
      {data.detail && (
        <span style={{ fontSize: 9.5, color: "var(--text-2)", paddingLeft: 17, lineHeight: 1.3 }}>
          {data.detail}
        </span>
      )}
      <Handle type="source" position={Position.Bottom} style={{ background: "var(--border)", width: 6, height: 6 }} />
    </div>
  );
});

const nodeTypes = { agentNode: AgentNodeComponent };

// ── Edge builder ─────────────────────────────────────────────────
function buildEdges(flowNodes: FlowNode[]): Edge[] {
  const edges: Edge[] = [];
  const byLayer: Record<number, FlowNode[]> = {};
  flowNodes.forEach((n) => {
    (byLayer[n.layer] ??= []).push(n);
  });

  const edgeStyle = { stroke: "var(--border)", strokeWidth: 1.5 };
  const marker = { type: MarkerType.ArrowClosed, width: 10, height: 10, color: "var(--border)" };

  // plan → each researcher
  byLayer[1]?.forEach((n) => {
    edges.push({ id: `e-plan-${n.id}`, source: "plan", target: n.id, animated: true, style: edgeStyle, markerEnd: marker });
  });

  // each synthesizer → fact_check
  const hasFc = flowNodes.some((n) => n.id === "fact_check");
  if (hasFc) {
    byLayer[2]?.forEach((n) => {
      edges.push({ id: `e-${n.id}-fc`, source: n.id, target: "fact_check", animated: true, style: edgeStyle, markerEnd: marker });
    });
  }

  // fact_check → write
  const hasWrite = flowNodes.some((n) => n.id === "write");
  if (hasFc && hasWrite) {
    edges.push({ id: "e-fc-write", source: "fact_check", target: "write", animated: true, style: edgeStyle, markerEnd: marker });
  }

  // simple path: researchers → write (no synthesizers)
  const writeNode = flowNodes.find((n) => n.id === "write");
  if (writeNode && writeNode.layer === 2 && !hasFc) {
    byLayer[1]?.forEach((n) => {
      edges.push({ id: `e-${n.id}-write`, source: n.id, target: "write", animated: true, style: edgeStyle, markerEnd: marker });
    });
  }

  return edges;
}

// ── Main component ───────────────────────────────────────────────
function GraphInner({ flowNodes }: { flowNodes: FlowNode[] }) {
  const { fitView } = useReactFlow();

  const layerCounters: Record<number, number> = {};
  const rfNodes: Node[] = flowNodes.map((fn) => {
    const idx = layerCounters[fn.layer] ?? 0;
    layerCounters[fn.layer] = idx + 1;
    return {
      id: fn.id,
      type: "agentNode",
      position: { x: nodeX(fn.layer, idx), y: LAYER_Y[fn.layer] ?? fn.layer * 150 },
      data: { label: fn.label, status: fn.status, detail: fn.detail },
    };
  });

  const rfEdges = buildEdges(flowNodes);

  const [nodes, , onNodesChange] = useNodesState(rfNodes);
  const [edges, , onEdgesChange] = useEdgesState(rfEdges);

  useEffect(() => {
    if (flowNodes.length > 0) fitView({ padding: 0.15, duration: 300 });
  }, [flowNodes.length, fitView]);

  return (
    <ReactFlow
      nodes={rfNodes}
      edges={rfEdges}
      onNodesChange={onNodesChange}
      onEdgesChange={onEdgesChange}
      nodeTypes={nodeTypes}
      fitView
      fitViewOptions={{ padding: 0.15 }}
      nodesDraggable={false}
      nodesConnectable={false}
      elementsSelectable={false}
      panOnDrag
      zoomOnScroll
      minZoom={0.3}
      maxZoom={1.5}
      proOptions={{ hideAttribution: true }}
    >
      <Background color="var(--border)" gap={24} size={1} />
      <Controls showInteractive={false} style={{ background: "var(--surface)", border: "1px solid var(--border)" }} />
    </ReactFlow>
  );
}

export default function AgentGraph({ flowNodes }: { flowNodes: FlowNode[] }) {
  return (
    <div style={{ width: "100%", height: "100%" }}>
      <ReactFlow
        nodes={(() => {
          const layerCounters: Record<number, number> = {};
          return flowNodes.map((fn) => {
            const idx = layerCounters[fn.layer] ?? 0;
            layerCounters[fn.layer] = idx + 1;
            return {
              id: fn.id,
              type: "agentNode",
              position: { x: nodeX(fn.layer, idx), y: LAYER_Y[fn.layer] ?? fn.layer * 150 },
              data: { label: fn.label, status: fn.status, detail: fn.detail },
            };
          });
        })()}
        edges={buildEdges(flowNodes)}
        nodeTypes={nodeTypes}
        fitView
        fitViewOptions={{ padding: 0.18 }}
        nodesDraggable={false}
        nodesConnectable={false}
        elementsSelectable={false}
        panOnDrag
        zoomOnScroll
        minZoom={0.25}
        maxZoom={1.5}
        proOptions={{ hideAttribution: true }}
      >
        <Background color="var(--border)" gap={24} size={1} />
        <Controls
          showInteractive={false}
          style={{ background: "var(--surface)", border: "1px solid var(--border)" }}
        />
      </ReactFlow>
    </div>
  );
}
