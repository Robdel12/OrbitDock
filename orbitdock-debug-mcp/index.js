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
            answers: {
              type: "object",
              description: "Optional map of question IDs to answer arrays for multi-question prompts",
              additionalProperties: {
                type: "array",
                items: { type: "string" },
              },
            },
            question_id: {
              type: "string",
              description: "Optional question ID for question approvals (defaults to pending question id when available)",
            },
            message: {
              type: "string",
              description: "Custom deny reason (Claude sessions — sent back to the agent)",
            },
            interrupt: {
              type: "boolean",
              description: "If true, stop the entire turn on deny (not just this tool call)",
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
              description: "Optional steering guidance text to inject into the active turn",
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
          required: ["session_id"],
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
        name: "set_permission_mode",
        description:
          "Change the permission mode for a Claude direct session. Controls what Claude can do without asking.",
        inputSchema: {
          type: "object",
          properties: {
            session_id: {
              type: "string",
              description: "Claude session ID",
            },
            mode: {
              type: "string",
              enum: ["default", "acceptEdits", "plan", "bypassPermissions"],
              description:
                "Permission mode: default (ask for everything), acceptEdits (auto-approve file edits), plan (read-only), bypassPermissions (auto-approve all)",
            },
          },
          required: ["session_id", "mode"],
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
      case "set_permission_mode":
        return await handleSetPermissionMode(args);
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

  // Only validate model against Codex model list for Codex sessions
  if (model && session.provider === "codex") {
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

async function handleApprove({
  session_id,
  request_id,
  approved,
  decision,
  type,
  answer,
  answers,
  question_id,
  message,
  interrupt,
}) {
  ensureOrbitDock();
  let session = await requireControllableSession(session_id);

  let resolvedRequestId = request_id;
  if (!resolvedRequestId || resolvedRequestId === "pending") {
    resolvedRequestId = session.pending_approval_id;
  }
  if (!resolvedRequestId) {
    throw new Error("No pending approval request_id available for this session.");
  }

  let pendingQuestion = parseQuestionMetadata(session.pending_tool_input);
  let resolvedType = type
    || session.pending_approval_type
    || (session.attention_reason === "awaitingQuestion" ? "question" : undefined)
    || "exec";
  if (!["exec", "patch", "question"].includes(resolvedType)) {
    throw new Error(`Invalid approval type '${resolvedType}'. Expected one of: exec, patch, question.`);
  }

  let resolvedDecision = decision;
  if (!resolvedDecision) {
    if (resolvedType === "question") {
      resolvedDecision = typeof approved === "boolean" ? (approved ? "approved" : "denied") : "approved";
    } else if (typeof approved === "boolean") {
      resolvedDecision = approved ? "approved" : "denied";
    } else {
      throw new Error("Missing decision. Provide 'decision' or legacy 'approved'.");
    }
  }

  let normalizedAnswer = typeof answer === "string" ? answer.trim() : "";
  let normalizedAnswers = normalizeQuestionAnswersMap(answers);
  let resolvedQuestionId = question_id || session.pending_question_id || pendingQuestion.questionId;
  if (resolvedType === "question" && Object.keys(normalizedAnswers).length === 0 && !normalizedAnswer) {
    let options = Array.isArray(session.pending_question_options) && session.pending_question_options.length > 0
      ? session.pending_question_options
      : pendingQuestion.options;
    let optionList = options
      .map((opt) => {
        let desc = opt.description ? `: ${opt.description}` : "";
        return `"${opt.label}"${desc}`;
      })
      .join("; ");
    let optionsHelp = optionList ? ` Available options: ${optionList}` : "";
    throw new Error(`Question approvals require a non-empty 'answer' or 'answers'.${optionsHelp}`);
  }

  if (resolvedType === "question") {
    if (Object.keys(normalizedAnswers).length === 0 && normalizedAnswer) {
      normalizedAnswers[resolvedQuestionId || "0"] = [normalizedAnswer];
    }

    if (!normalizedAnswer) {
      normalizedAnswer = firstQuestionAnswer(normalizedAnswers, resolvedQuestionId) || "";
    }

    if (!resolvedQuestionId) {
      let keys = Object.keys(normalizedAnswers);
      resolvedQuestionId = keys.length > 0 ? keys[0] : undefined;
    }
  }

  await orbitdock.approve(session_id, resolvedRequestId, {
    type: resolvedType,
    decision: resolvedDecision,
    answer: normalizedAnswer || undefined,
    answers: Object.keys(normalizedAnswers).length > 0 ? normalizedAnswers : undefined,
    question_id: resolvedQuestionId,
    message,
    interrupt,
  });

  let statusText = resolvedType === "question" ? "answered" : resolvedDecision;
  return {
    content: [
      {
        type: "text",
        text: `${resolvedType} ${statusText} for ${session_id} (${resolvedRequestId})`,
      },
    ],
  };
}

async function handleSteerTurn({ session_id, content, images, mentions }) {
  ensureOrbitDock();
  await requireControllableSession(session_id);

  await orbitdock.steerTurn(session_id, content, { images, mentions });

  let parts = [
    `Steering guidance sent to ${session_id}. If a turn was active, it received the input. Otherwise, a new turn was started.`,
  ];
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

async function handleSetPermissionMode({ session_id, mode }) {
  ensureOrbitDock();
  let session = await requireControllableSession(session_id);

  if (session.provider !== "claude") {
    throw new Error(`set_permission_mode is only available for Claude sessions (this is ${session.provider})`);
  }

  await orbitdock.setPermissionMode(session_id, mode);

  return {
    content: [
      {
        type: "text",
        text: `Permission mode set to '${mode}' for ${session_id}`,
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
  if (session.permission_mode) {
    lines.push(`Permission mode: ${session.permission_mode}`);
  }
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

function normalizeQuestionAnswersMap(rawAnswers) {
  if (!rawAnswers || typeof rawAnswers !== "object" || Array.isArray(rawAnswers)) {
    return {};
  }

  let normalized = {};
  for (let [rawQuestionId, rawValues] of Object.entries(rawAnswers)) {
    let questionId = typeof rawQuestionId === "string" ? rawQuestionId.trim() : "";
    if (!questionId) continue;

    let values = [];
    if (Array.isArray(rawValues)) {
      values = rawValues
        .map((value) => (typeof value === "string" ? value.trim() : ""))
        .filter((value) => Boolean(value));
    } else if (typeof rawValues === "string") {
      let trimmed = rawValues.trim();
      if (trimmed) values = [trimmed];
    }

    if (values.length > 0) {
      normalized[questionId] = values;
    }
  }

  return normalized;
}

function firstQuestionAnswer(answersMap, preferredQuestionId) {
  if (!answersMap || typeof answersMap !== "object") return undefined;
  if (preferredQuestionId
    && Array.isArray(answersMap[preferredQuestionId])
    && answersMap[preferredQuestionId].length > 0
  ) {
    return answersMap[preferredQuestionId][0];
  }

  for (let values of Object.values(answersMap)) {
    if (Array.isArray(values) && values.length > 0 && values[0]) {
      return values[0];
    }
  }

  return undefined;
}

function parseQuestionMetadata(toolInput) {
  let empty = { questionId: undefined, question: undefined, options: [] };
  if (!toolInput || typeof toolInput !== "string") {
    return empty;
  }

  try {
    let parsed = JSON.parse(toolInput);
    let questionPayload = undefined;
    if (Array.isArray(parsed.questions) && parsed.questions.length > 0) {
      questionPayload = parsed.questions[0];
    } else if (parsed.question || Array.isArray(parsed.options)) {
      questionPayload = parsed;
    }
    if (!questionPayload || typeof questionPayload !== "object") {
      return empty;
    }

    let options = Array.isArray(questionPayload.options)
      ? questionPayload.options
        .map((opt) => {
          if (!opt || typeof opt !== "object") return null;
          let label = typeof opt.label === "string" ? opt.label.trim() : "";
          if (!label) return null;
          let description = typeof opt.description === "string" ? opt.description.trim() : "";
          return description ? { label, description } : { label };
        })
        .filter(Boolean)
      : [];

    return {
      questionId: typeof questionPayload.id === "string" ? questionPayload.id : undefined,
      question: typeof questionPayload.question === "string" ? questionPayload.question : undefined,
      options,
    };
  } catch {
    return empty;
  }
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
