/**
 * HTTP client for OrbitDock's MCP Bridge
 * Sends commands to OrbitDock which forwards them to provider runtimes (Claude, Codex)
 */
export class OrbitDockClient {
  constructor(port = 19384) {
    this.baseUrl = `http://127.0.0.1:${port}`;
  }

  /**
   * Check if OrbitDock is running and the MCP Bridge is available
   */
  async health() {
    let response = await this.request("GET", "/api/health");
    return response;
  }

  /**
   * List active sessions
   */
  async listSessions() {
    let response = await this.request("GET", "/api/sessions");
    return response.sessions || [];
  }

  /**
   * Get a specific session by ID
   */
  async getSession(sessionId) {
    let response = await this.request("GET", `/api/sessions/${sessionId}`);
    return response;
  }

  /**
   * List supported models discovered by OrbitDock server
   */
  async listModels() {
    let response = await this.request("GET", "/api/models");
    return response.models || [];
  }

  /**
   * Send a message to a session (starts a new turn)
   * @param {Object} [options] - Optional per-turn overrides
   * @param {string} [options.model] - Model override for this turn
   * @param {string} [options.effort] - Reasoning effort override (low/medium/high)
   * @param {Array} [options.images] - Images to attach ({input_type, value})
   * @param {Array} [options.mentions] - File mentions to attach ({name, path})
   */
  async sendMessage(sessionId, message, options = {}) {
    let body = { message };
    if (options.model) body.model = options.model;
    if (options.effort) body.effort = options.effort;
    if (options.images && options.images.length > 0) body.images = options.images;
    if (options.mentions && options.mentions.length > 0) body.mentions = options.mentions;
    let response = await this.request("POST", `/api/sessions/${sessionId}/message`, body);
    return response;
  }

  /**
   * Interrupt the current turn
   */
  async interruptTurn(sessionId) {
    let response = await this.request("POST", `/api/sessions/${sessionId}/interrupt`);
    return response;
  }

  /**
   * Approve or reject an exec/patch request
   */
  async approve(sessionId, requestId, options = {}) {
    let body = {
      request_id: requestId,
      type: options.type || "exec",
    };
    if (options.decision) {
      body.decision = options.decision;
    } else if (typeof options.approved === "boolean") {
      body.approved = options.approved;
    }
    if (options.answer) {
      body.answer = options.answer;
    }
    if (options.message) {
      body.message = options.message;
    }
    if (options.interrupt != null) {
      body.interrupt = options.interrupt;
    }
    let response = await this.request("POST", `/api/sessions/${sessionId}/approve`, body);
    return response;
  }

  /**
   * Fork a session (creates a new session with conversation history)
   * @param {string} sessionId - Source session ID to fork from
   * @param {Object} [options] - Fork options
   * @param {number} [options.nth_user_message] - Fork at this user message index (0-based). Omit for full fork.
   */
  async forkSession(sessionId, options = {}) {
    let body = {};
    if (options.nth_user_message != null) body.nth_user_message = options.nth_user_message;
    let response = await this.request("POST", `/api/sessions/${sessionId}/fork`, body);
    return response;
  }

  /**
   * Set the permission mode for a Claude direct session
   */
  async setPermissionMode(sessionId, mode) {
    let response = await this.request("POST", `/api/sessions/${sessionId}/permission-mode`, { mode });
    return response;
  }

  /**
   * Steer the active turn with additional guidance
   */
  async steerTurn(sessionId, content) {
    let response = await this.request("POST", `/api/sessions/${sessionId}/steer`, { content });
    return response;
  }

  /**
   * Make an HTTP request to OrbitDock
   */
  async request(method, path, body = null) {
    let url = `${this.baseUrl}${path}`;

    let options = {
      method,
      headers: {
        "Content-Type": "application/json",
      },
    };

    if (body) {
      options.body = JSON.stringify(body);
    }

    let response = await fetch(url, options);
    let data = await response.json();

    if (!response.ok) {
      throw new Error(data.error || `HTTP ${response.status}`);
    }

    return data;
  }
}
