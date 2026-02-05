/**
 * HTTP client for OrbitDock's MCP Bridge
 * Sends commands to OrbitDock which forwards them to the Codex app-server
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
   * Send a message to a session (starts a new turn)
   */
  async sendMessage(sessionId, message) {
    let response = await this.request("POST", `/api/sessions/${sessionId}/message`, {
      message,
    });
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
  async approve(sessionId, requestId, approved, type = "exec", answers = null) {
    let body = { request_id: requestId, approved, type };
    if (answers) {
      body.answers = answers;
    }
    let response = await this.request("POST", `/api/sessions/${sessionId}/approve`, body);
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
