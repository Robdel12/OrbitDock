#!/bin/bash

# OrbitDock Installer
# Sets up hooks and MCP server configuration

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$HOME/.claude/hooks"
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
if [ -f "$HOOKS_DIR/session-start.sh" ]; then
  mkdir -p "$HOOKS_DIR/backup"
  for f in "$HOOKS_DIR"/*.sh; do
    [ -f "$f" ] && cp "$f" "$HOOKS_DIR/backup/"
  done
  echo "   Backed up to $HOOKS_DIR/backup/"
fi

# Install Node.js hooks (replace bash scripts)
echo "🔧 Installing hooks..."

cat > "$HOOKS_DIR/session-start.sh" << 'EOF'
#!/bin/bash
# OrbitDock session-start hook (Node.js)
node "SCRIPT_DIR/src/hooks/session-start.js"
EOF
sed -i '' "s|SCRIPT_DIR|$SCRIPT_DIR|g" "$HOOKS_DIR/session-start.sh"

cat > "$HOOKS_DIR/session-end.sh" << 'EOF'
#!/bin/bash
# OrbitDock session-end hook (Node.js)
node "SCRIPT_DIR/src/hooks/session-end.js"
EOF
sed -i '' "s|SCRIPT_DIR|$SCRIPT_DIR|g" "$HOOKS_DIR/session-end.sh"

cat > "$HOOKS_DIR/tool-tracker.sh" << 'EOF'
#!/bin/bash
# OrbitDock tool-tracker hook (Node.js)
node "SCRIPT_DIR/src/hooks/tool-tracker.js"
EOF
sed -i '' "s|SCRIPT_DIR|$SCRIPT_DIR|g" "$HOOKS_DIR/tool-tracker.sh"

cat > "$HOOKS_DIR/status-tracker.sh" << 'EOF'
#!/bin/bash
# OrbitDock status-tracker hook (Node.js)
node "SCRIPT_DIR/src/hooks/status-tracker.js"
EOF
sed -i '' "s|SCRIPT_DIR|$SCRIPT_DIR|g" "$HOOKS_DIR/status-tracker.sh"

chmod +x "$HOOKS_DIR"/*.sh

# Clean up the hooks.json we mistakenly created
rm -f "$HOME/.claude/hooks.json"

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
  args: [\`\${scriptDir}/src/server.js\`],
  env: {}
};

fs.writeFileSync('$MCP_CONFIG', JSON.stringify(config, null, 2));
console.log('MCP server configured');
"

echo ""
echo "✅ OrbitDock installed!"
echo ""
echo "Hooks installed to: $HOOKS_DIR"
echo "  • session-start.sh"
echo "  • session-end.sh"
echo "  • tool-tracker.sh"
echo "  • status-tracker.sh"
echo ""
echo "MCP server configured in: $MCP_CONFIG"
echo "Database location: ~/.orbitdock/orbitdock.db"
echo ""
echo "Restart Claude Code to activate."
