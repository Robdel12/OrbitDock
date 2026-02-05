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
    version: "0.2.0",
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
          "Send a user message to a Codex session through OrbitDock. Starts a new turn in the conversation.",
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
          },
          required: ["session_id", "message"],
        },
      },
      {
        name: "interrupt_turn",
        description: "Interrupt/stop the current turn in a Codex session",
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
        description: "Approve or reject a pending tool execution (command or file change) in a Codex session",
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
            approved: {
              type: "boolean",
              description: "Whether to approve (true) or reject (false)",
            },
            type: {
              type: "string",
              enum: ["exec", "patch", "question"],
              description: "Type of approval (default: exec)",
            },
          },
          required: ["session_id", "request_id", "approved"],
        },
      },
      {
        name: "list_sessions",
        description: "List active Codex sessions from OrbitDock that can be controlled",
        inputSchema: {
          type: "object",
          properties: {},
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

async function handleSendMessage({ session_id, message }) {
  ensureOrbitDock();
  await orbitdock.sendMessage(session_id, message);

  return {
    content: [
      {
        type: "text",
        text: `Message sent to ${session_id}. Turn started.`,
      },
    ],
  };
}

async function handleInterruptTurn({ session_id }) {
  ensureOrbitDock();
  await orbitdock.interruptTurn(session_id);

  return {
    content: [{ type: "text", text: `Turn interrupted for ${session_id}` }],
  };
}

async function handleApprove({ session_id, request_id, approved, type = "exec" }) {
  ensureOrbitDock();
  await orbitdock.approve(session_id, request_id, approved, type);

  return {
    content: [
      {
        type: "text",
        text: `${type} ${approved ? "approved" : "rejected"} for ${session_id}`,
      },
    ],
  };
}

async function handleListSessions() {
  ensureOrbitDock();
  let sessions = await orbitdock.listSessions();

  // Filter to only Codex direct sessions (controllable)
  let codexSessions = sessions.filter((s) => s.is_direct_codex);

  if (codexSessions.length === 0) {
    return {
      content: [{ type: "text", text: "No active Codex sessions found." }],
    };
  }

  let summary = codexSessions
    .map((s) => {
      let status = s.work_status;
      if (s.attention_reason && s.attention_reason !== "none") {
        status += ` (${s.attention_reason})`;
      }
      return `• ${s.id}\n  ${s.project_path}\n  Status: ${status}`;
    })
    .join("\n\n");

  return {
    content: [{ type: "text", text: summary }],
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
