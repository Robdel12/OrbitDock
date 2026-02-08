#!/usr/bin/env node

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";

import { OrbitDockClient } from "./lib/orbitdock-client.js";

let orbitdock = null;

const server = new Server(
  {
    name: "orbitdock",
    version: "0.3.0",
  },
  {
    capabilities: {
      tools: {},
    },
  }
);

// Define available tools - session control only
server.setRequestHandler(ListToolsRequestSchema, async () => {
  return {
    tools: [
      {
        name: "send_message",
        description:
          "Send a user message to a controllable OrbitDock session. Currently supports direct Codex sessions.",
        inputSchema: {
          type: "object",
          properties: {
            session_id: {
              type: "string",
              description: "Session ID (e.g., codex-direct-xxx)",
            },
            message: {
              type: "string",
              description: "The user message/prompt to send",
            },
            model: {
              type: "string",
              description: "Optional model override for this turn (e.g., 'o3', 'o4-mini', 'gpt-4o')",
            },
            effort: {
              type: "string",
              enum: ["low", "medium", "high"],
              description: "Optional reasoning effort override for this turn",
            },
          },
          required: ["session_id", "message"],
        },
      },
      {
        name: "interrupt_turn",
        description: "Interrupt/stop the current turn in a controllable OrbitDock session (direct Codex)",
        inputSchema: {
          type: "object",
          properties: {
            session_id: {
              type: "string",
              description: "Session ID to interrupt",
            },
          },
          required: ["session_id"],
        },
      },
      {
        name: "approve",
        description: "Approve/reject a pending tool execution in a controllable OrbitDock session (direct Codex)",
        inputSchema: {
          type: "object",
          properties: {
            session_id: {
              type: "string",
              description: "Session ID",
            },
            request_id: {
              type: "string",
              description: "The approval request ID (from pending_approval_id in session)",
            },
            decision: {
              type: "string",
              enum: ["approved", "approved_for_session", "approved_always", "denied", "abort"],
              description:
                "Explicit decision. Preferred over legacy 'approved' bool.",
            },
            approved: {
              type: "boolean",
              description: "Legacy fallback: true => approved, false => denied",
            },
            type: {
              type: "string",
              enum: ["exec", "patch", "question"],
              description: "Type of approval (default: exec)",
            },
            answer: {
              type: "string",
              description: "Answer for question approvals (required when type=question)",
            },
          },
          required: ["session_id", "request_id"],
        },
      },
      {
        name: "list_sessions",
        description: "List active OrbitDock sessions (Codex and/or Claude) with controllability metadata",
        inputSchema: {
          type: "object",
          properties: {
            provider: {
              type: "string",
              enum: ["any", "codex", "claude"],
              description: "Optional provider filter (default: any)",
            },
            controllable_only: {
              type: "boolean",
              description:
                "If true, only include sessions controllable via MCP actions (default: false)",
            },
          },
        },
      },
      {
        name: "get_session",
        description: "Get details for one OrbitDock session by ID",
        inputSchema: {
          type: "object",
          properties: {
            session_id: {
              type: "string",
              description: "Session ID",
            },
          },
          required: ["session_id"],
        },
      },
      {
        name: "check_connection",
        description: "Check if OrbitDock is running and the MCP bridge is available",
        inputSchema: {
          type: "object",
          properties: {},
        },
      },
    ],
  };
});

// Handle tool calls
server.setRequestHandler(CallToolRequestSchema, async (request) => {
  let { name, arguments: args } = request.params;
  args = args || {};

  try {
    switch (name) {
      case "send_message":
        return await handleSendMessage(args);
      case "interrupt_turn":
        return await handleInterruptTurn(args);
      case "approve":
        return await handleApprove(args);
      case "list_sessions":
        return await handleListSessions(args);
      case "get_session":
        return await handleGetSession(args);
      case "check_connection":
        return await handleCheckConnection(args);
      default:
        return { content: [{ type: "text", text: `Unknown tool: ${name}` }], isError: true };
    }
  } catch (error) {
    return {
      content: [{ type: "text", text: `Error: ${error.message}` }],
      isError: true,
    };
  }
});

// Tool handlers

async function handleSendMessage({ session_id, message, model, effort }) {
  ensureOrbitDock();
  let session = await requireControllableSession(session_id);
  await orbitdock.sendMessage(session_id, message, { model, effort });

  return {
    content: [
      {
        type: "text",
        text: `Message sent to ${session_id} (${session.provider}). Turn started.`,
      },
    ],
  };
}

async function handleInterruptTurn({ session_id }) {
  ensureOrbitDock();
  await requireControllableSession(session_id);
  await orbitdock.interruptTurn(session_id);

  return {
    content: [{ type: "text", text: `Turn interrupted for ${session_id}` }],
  };
}

async function handleApprove({ session_id, request_id, approved, decision, type = "exec", answer }) {
  ensureOrbitDock();
  await requireControllableSession(session_id);

  let resolvedDecision = decision;
  if (!resolvedDecision) {
    if (typeof approved === "boolean") {
      resolvedDecision = approved ? "approved" : "denied";
    } else {
      throw new Error("Missing decision. Provide 'decision' or legacy 'approved'.");
    }
  }

  await orbitdock.approve(session_id, request_id, {
    type,
    decision: resolvedDecision,
    answer,
  });

  return {
    content: [
      {
        type: "text",
        text: `${type} ${resolvedDecision} for ${session_id}`,
      },
    ],
  };
}

async function handleListSessions({ provider = "any", controllable_only = false } = {}) {
  ensureOrbitDock();
  let sessions = await orbitdock.listSessions();

  let filtered = sessions.filter((s) => {
    if (provider !== "any" && s.provider !== provider) {
      return false;
    }
    if (controllable_only && !isControllableSession(s)) {
      return false;
    }
    return true;
  });

  if (filtered.length === 0) {
    let scope = provider === "any" ? "matching" : provider;
    let mode = controllable_only ? "controllable " : "";
    return {
      content: [{ type: "text", text: `No active ${mode}${scope} sessions found.` }],
    };
  }

  let summary = filtered
    .map((s) => {
      let status = s.work_status;
      if (s.attention_reason && s.attention_reason !== "none") {
        status += ` (${s.attention_reason})`;
      }
      let controllable = isControllableSession(s) ? "yes" : "no";
      return `• ${s.id}\n  Provider: ${s.provider}\n  ${s.project_path}\n  Status: ${status}\n  Controllable: ${controllable}`;
    })
    .join("\n\n");

  return {
    content: [{ type: "text", text: summary }],
  };
}

async function handleGetSession({ session_id }) {
  ensureOrbitDock();
  let session = await orbitdock.getSession(session_id);

  let lines = [
    `ID: ${session.id}`,
    `Provider: ${session.provider}`,
    `Project: ${session.project_path}`,
    `Status: ${session.work_status}${session.attention_reason && session.attention_reason !== "none" ? ` (${session.attention_reason})` : ""}`,
    `Direct Codex: ${session.is_direct_codex ? "yes" : "no"}`,
    `Controllable: ${isControllableSession(session) ? "yes" : "no"}`,
  ];

  return {
    content: [{ type: "text", text: lines.join("\n") }],
  };
}

async function handleCheckConnection() {
  ensureOrbitDock();

  try {
    let health = await orbitdock.health();
    return {
      content: [
        {
          type: "text",
          text: `OrbitDock connected (port ${health.port})`,
        },
      ],
    };
  } catch (error) {
    return {
      content: [
        {
          type: "text",
          text: `Not connected: ${error.message}\nMake sure OrbitDock is running.`,
        },
      ],
      isError: true,
    };
  }
}

// Helpers

function ensureOrbitDock() {
  if (!orbitdock) {
    orbitdock = new OrbitDockClient();
  }
}

function isControllableSession(session) {
  return session.provider === "codex" && session.is_direct_codex;
}

async function requireControllableSession(sessionId) {
  let session = await orbitdock.getSession(sessionId);
  if (!isControllableSession(session)) {
    throw new Error(
      `Session ${sessionId} is provider=${session.provider}, direct_codex=${session.is_direct_codex}. ` +
        "Only direct Codex sessions are currently controllable via MCP actions."
    );
  }
  return session;
}

// Start the server
async function main() {
  let transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("OrbitDock MCP running");
}

main().catch((error) => {
  console.error("Fatal error:", error);
  process.exit(1);
});
