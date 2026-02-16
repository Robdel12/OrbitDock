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
          "Send a user message to a controllable OrbitDock session. Currently supports direct Codex and Claude sessions.",
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
            images: {
              type: "array",
              description: "Optional images to attach (data URIs or local file paths)",
              items: {
                type: "object",
                properties: {
                  input_type: {
                    type: "string",
                    enum: ["url", "path"],
                    description: "'url' for data URI, 'path' for local file",
                  },
                  value: {
                    type: "string",
                    description: "Data URI string or local file path",
                  },
                },
                required: ["input_type", "value"],
              },
            },
            mentions: {
              type: "array",
              description: "Optional file/resource mentions to attach",
              items: {
                type: "object",
                properties: {
                  name: {
                    type: "string",
                    description: "Display name of the mentioned file/resource",
                  },
                  path: {
                    type: "string",
                    description: "Path or URI of the mentioned file/resource",
                  },
                },
                required: ["name", "path"],
              },
            },
          },
          required: ["session_id", "message"],
        },
      },
      {
        name: "interrupt_turn",
        description: "Interrupt/stop the current turn in a controllable OrbitDock session (direct Codex or Claude)",
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
        description: "Approve/reject a pending tool execution in a controllable OrbitDock session (direct Codex or Claude)",
        inputSchema: {
          type: "object",
          properties: {
            session_id: {
              type: "string",
              description: "Session ID",
            },
            request_id: {
              type: "string",
              description: "Optional approval request ID; if omitted or 'pending', bridge resolves pending_approval_id",
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
          required: ["session_id"],
        },
      },
      {
        name: "steer_turn",
        description:
          "Inject guidance into an active turn without stopping it. If no turn is active, falls back to starting a new turn.",
        inputSchema: {
          type: "object",
          properties: {
            session_id: {
              type: "string",
              description: "Session ID",
            },
            content: {
              type: "string",
              description: "Steering guidance to inject into the active turn",
            },
          },
          required: ["session_id", "content"],
        },
      },
      {
        name: "fork_session",
        description:
          "Fork a session, creating a new session with conversation history. Optionally fork from a specific user message.",
        inputSchema: {
          type: "object",
          properties: {
            session_id: {
              type: "string",
              description: "Source session ID to fork from",
            },
            nth_user_message: {
              type: "integer",
              description:
                "Fork at this user message index (0-based). Omit to fork the full conversation.",
            },
          },
          required: ["session_id"],
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
      {
        name: "list_models",
        description: "List Codex models currently available for this OrbitDock/Codex account",
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
      case "steer_turn":
        return await handleSteerTurn(args);
      case "fork_session":
        return await handleForkSession(args);
      case "list_sessions":
        return await handleListSessions(args);
      case "get_session":
        return await handleGetSession(args);
      case "check_connection":
        return await handleCheckConnection(args);
      case "list_models":
        return await handleListModels();
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

async function handleSendMessage({ session_id, message, model, effort, images, mentions }) {
  ensureOrbitDock();
  let session = await requireControllableSession(session_id);

  if (model) {
    let models = await orbitdock.listModels();
    if (models.length > 0 && !models.some((m) => m.model === model)) {
      let available = models.slice(0, 10).map((m) => m.model).join(", ");
      throw new Error(
        `Model '${model}' is not in current server model list. Available examples: ${available}`
      );
    }
  }

  await orbitdock.sendMessage(session_id, message, { model, effort, images, mentions });

  let parts = [`Message sent to ${session_id} (${session.provider}). Turn started.`];
  if (images && images.length > 0) parts.push(`Attached ${images.length} image(s).`);
  if (mentions && mentions.length > 0) parts.push(`Attached ${mentions.length} mention(s).`);

  return {
    content: [
      {
        type: "text",
        text: parts.join(" "),
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

  let resolvedRequestId = request_id;
  if (!resolvedRequestId || resolvedRequestId === "pending") {
    let session = await orbitdock.getSession(session_id);
    resolvedRequestId = session.pending_approval_id;
  }
  if (!resolvedRequestId) {
    throw new Error("No pending approval request_id available for this session.");
  }

  let resolvedDecision = decision;
  if (!resolvedDecision) {
    if (typeof approved === "boolean") {
      resolvedDecision = approved ? "approved" : "denied";
    } else {
      throw new Error("Missing decision. Provide 'decision' or legacy 'approved'.");
    }
  }

  await orbitdock.approve(session_id, resolvedRequestId, {
    type,
    decision: resolvedDecision,
    answer,
  });

  return {
    content: [
      {
        type: "text",
        text: `${type} ${resolvedDecision} for ${session_id} (${resolvedRequestId})`,
      },
    ],
  };
}

async function handleSteerTurn({ session_id, content }) {
  ensureOrbitDock();
  await requireControllableSession(session_id);

  await orbitdock.steerTurn(session_id, content);

  return {
    content: [
      {
        type: "text",
        text: `Steering guidance sent to ${session_id}. If a turn was active, it received the input. Otherwise, a new turn was started.`,
      },
    ],
  };
}

async function handleForkSession({ session_id, nth_user_message }) {
  ensureOrbitDock();
  let session = await requireControllableSession(session_id);

  let options = {};
  if (nth_user_message != null) options.nth_user_message = nth_user_message;

  await orbitdock.forkSession(session_id, options);

  let turnInfo = nth_user_message != null ? ` from user message #${nth_user_message}` : " (full conversation)";
  return {
    content: [
      {
        type: "text",
        text: `Fork requested for ${session_id}${turnInfo}. The new session will appear in OrbitDock once created.`,
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
    `Direct: ${session.is_direct ? "yes" : "no"}`,
    `Controllable: ${isControllableSession(session) ? "yes" : "no"}`,
  ];
  if (session.pending_approval_id) {
    lines.push(`Pending approval: ${session.pending_approval_id}`);
  }

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

async function handleListModels() {
  ensureOrbitDock();
  let models = await orbitdock.listModels();
  if (models.length === 0) {
    return {
      content: [{ type: "text", text: "No models returned yet. OrbitDock may still be loading model metadata." }],
    };
  }

  let lines = models.map((m) => {
    let effort = Array.isArray(m.supported_reasoning_efforts)
      ? m.supported_reasoning_efforts.join(", ")
      : "";
    let defaultFlag = m.is_default ? " (default)" : "";
    return `• ${m.model}${defaultFlag}\n  ${m.display_name}\n  Effort: ${effort}`;
  });
  return { content: [{ type: "text", text: lines.join("\n\n") }] };
}

// Helpers

function ensureOrbitDock() {
  if (!orbitdock) {
    orbitdock = new OrbitDockClient();
  }
}

function isControllableSession(session) {
  return session.is_direct || (session.provider === "codex" && session.is_direct_codex) || (session.provider === "claude" && session.is_direct_claude);
}

async function requireControllableSession(sessionId) {
  let session = await orbitdock.getSession(sessionId);
  if (!isControllableSession(session)) {
    throw new Error(
      `Session ${sessionId} is provider=${session.provider}, direct=${session.is_direct}. ` +
        "Only direct Codex or Claude sessions are controllable via MCP actions."
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
