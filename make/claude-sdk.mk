.PHONY: claude-sdk-version claude-sdk-update claude-sdk-audit-checklist

claude-sdk-version:
	@node -e 'const fs=require("fs");const path="$(CLAUDE_SDK_DOCS_DIR)/node_modules/@anthropic-ai/claude-agent-sdk/package.json";if(!fs.existsSync(path)){console.error("Claude Agent SDK not installed: "+path);process.exit(1);}const pkg=JSON.parse(fs.readFileSync(path,"utf8"));console.log(`${pkg.name}@${pkg.version} (claudeCodeVersion=${pkg.claudeCodeVersion??"unknown"})`);'

claude-sdk-update:
	cd $(CLAUDE_SDK_DOCS_DIR) && npm install $(CLAUDE_SDK_PACKAGE)@$(CLAUDE_SDK_VERSION)
	@node -e 'const fs=require("fs");const pkgPath="$(CLAUDE_SDK_DOCS_DIR)/node_modules/@anthropic-ai/claude-agent-sdk/package.json";if(!fs.existsSync(pkgPath)){console.error("Missing installed SDK package: "+pkgPath);process.exit(1);}const pkg=JSON.parse(fs.readFileSync(pkgPath,"utf8"));const out={packageName:pkg.name,sdkVersion:pkg.version,claudeCodeVersion:pkg.claudeCodeVersion??null,sourcePath:"orbitdock-server/docs/node_modules/@anthropic-ai/claude-agent-sdk",officialOverview:"https://platform.claude.com/docs/en/agent-sdk/overview",auditDoc:`orbitdock-server/docs/claude-agent-sdk-${pkg.version}-source-audit.md`};fs.writeFileSync("$(CLAUDE_SDK_VERSION_FILE)",JSON.stringify(out,null,2)+"\n");console.log(`Wrote $(CLAUDE_SDK_VERSION_FILE)`);'

claude-sdk-audit-checklist:
	@echo "Claude Agent SDK audit checklist:"
	@echo "1. Update local install: make claude-sdk-update CLAUDE_SDK_VERSION=<version>"
	@echo "2. Inspect source of truth files:"
	@echo "   - orbitdock-server/docs/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs"
	@echo "   - orbitdock-server/docs/node_modules/@anthropic-ai/claude-agent-sdk/sdk.d.ts"
	@echo "   - orbitdock-server/docs/node_modules/@anthropic-ai/claude-agent-sdk/sdk-tools.d.ts"
	@echo "   - orbitdock-server/docs/node_modules/@anthropic-ai/claude-agent-sdk/cli.js"
	@echo "3. Record findings in a local ignored note if needed"
	@echo "4. Generated metadata is local-only: orbitdock-server/docs/claude-agent-sdk-version.json"
	@echo "5. If official docs differ, treat local source as truth"
