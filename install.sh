#!/bin/bash

# OrbitDock Installer
# Sets up hooks and MCP server configuration

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$HOME/.claude/hooks"
SETTINGS_FILE="$HOME/.claude/settings.json"
MCP_CONFIG="$HOME/.claude/mcp.json"

echo "🚀 Installing OrbitDock..."

# Ensure directories exist
mkdir -p "$HOOKS_DIR"
mkdir -p "$HOME/.orbitdock"

# Install npm dependencies
echo "📦 Installing dependencies..."
cd "$SCRIPT_DIR"
npm install

# Backup existing hooks
echo "📁 Backing up existing hooks..."
if [ -f "$HOOKS_DIR/session-start.js" ] || [ -f "$HOOKS_DIR/session-start.sh" ]; then
  mkdir -p "$HOOKS_DIR/backup"
  for f in "$HOOKS_DIR"/session-*.js "$HOOKS_DIR"/session-*.sh "$HOOKS_DIR"/tool-*.sh "$HOOKS_DIR"/status-*.sh 2>/dev/null; do
    [ -f "$f" ] && cp "$f" "$HOOKS_DIR/backup/"
  done
  echo "   Backed up to $HOOKS_DIR/backup/"
fi

# Copy Node.js hooks directly
echo "🔧 Installing hooks..."
cp "$SCRIPT_DIR/hooks/session-start.js" "$HOOKS_DIR/"
cp "$SCRIPT_DIR/hooks/session-end.js" "$HOOKS_DIR/"
cp "$SCRIPT_DIR/hooks/tool-tracker.js" "$HOOKS_DIR/"
cp "$SCRIPT_DIR/hooks/status-tracker.js" "$HOOKS_DIR/"

# Make them executable
chmod +x "$HOOKS_DIR"/*.js

# Update settings.json with hook configuration
echo "⚙️  Configuring hooks in settings.json..."
node -e "
const fs = require('fs');
const path = require('path');

const settingsPath = '$SETTINGS_FILE';
const hooksDir = '$HOOKS_DIR';

let settings = {};
if (fs.existsSync(settingsPath)) {
  settings = JSON.parse(fs.readFileSync(settingsPath, 'utf-8'));
}

settings.hooks = {
  SessionStart: [{
    hooks: [{
      type: 'command',
      command: 'node ' + path.join(hooksDir, 'session-start.js'),
      async: true
    }]
  }],
  SessionEnd: [{
    hooks: [{
      type: 'command',
      command: 'node ' + path.join(hooksDir, 'session-end.js'),
      async: true
    }]
  }],
  UserPromptSubmit: [{
    hooks: [{
      type: 'command',
      command: 'node ' + path.join(hooksDir, 'status-tracker.js'),
      async: true
    }]
  }],
  Stop: [{
    hooks: [{
      type: 'command',
      command: 'node ' + path.join(hooksDir, 'status-tracker.js'),
      async: true
    }]
  }],
  Notification: [{
    matcher: 'idle_prompt|permission_prompt',
    hooks: [{
      type: 'command',
      command: 'node ' + path.join(hooksDir, 'status-tracker.js'),
      async: true
    }]
  }],
  PreToolUse: [{
    hooks: [{
      type: 'command',
      command: 'node ' + path.join(hooksDir, 'tool-tracker.js'),
      async: true
    }]
  }],
  PostToolUse: [{
    hooks: [{
      type: 'command',
      command: 'node ' + path.join(hooksDir, 'tool-tracker.js'),
      async: true
    }]
  }]
};

fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2));
console.log('Hooks configured in settings.json');
"

# Set up MCP server
echo "🔌 Setting up MCP server..."

if [ ! -f "$MCP_CONFIG" ]; then
  echo '{"mcpServers":{}}' > "$MCP_CONFIG"
fi

node -e "
const fs = require('fs');
const config = JSON.parse(fs.readFileSync('$MCP_CONFIG', 'utf-8'));
const scriptDir = '$SCRIPT_DIR';

config.mcpServers = config.mcpServers || {};
config.mcpServers.orbitdock = {
  command: 'node',
  args: [scriptDir + '/mcp-server/server.js'],
  env: {}
};

fs.writeFileSync('$MCP_CONFIG', JSON.stringify(config, null, 2));
console.log('MCP server configured');
"

# Clean up old bash hooks and hooks.json
rm -f "$HOOKS_DIR"/*.sh 2>/dev/null || true
rm -f "$HOME/.claude/hooks.json" 2>/dev/null || true

echo ""
echo "✅ OrbitDock installed!"
echo ""
echo "Hooks installed to: $HOOKS_DIR"
echo "  • session-start.js"
echo "  • session-end.js"
echo "  • tool-tracker.js"
echo "  • status-tracker.js"
echo ""
echo "MCP server configured in: $MCP_CONFIG"
echo "Database location: ~/.orbitdock/orbitdock.db"
echo ""
echo "Restart Claude Code to activate."
