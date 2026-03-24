.PHONY: web-install web-dev web-build web-test web-test-e2e web-lint web-lint-fix web-fmt web-fmt-check web-ci

web-install:
	cd $(WEB_APP_DIR) && npm install

web-dev:
	cd $(WEB_APP_DIR) && npm run dev

web-build:
	cd $(WEB_APP_DIR) && npm run build

web-test:
	cd $(WEB_APP_DIR) && npm test

web-test-e2e:
	cd $(WEB_APP_DIR) && npm run test:e2e

web-lint:
	cd $(WEB_APP_DIR) && npm run lint

web-lint-fix:
	cd $(WEB_APP_DIR) && npm run lint:fix

web-fmt:
	cd $(WEB_APP_DIR) && npm run format

web-fmt-check:
	cd $(WEB_APP_DIR) && npm run format:check

web-ci: web-lint web-build web-test web-test-e2e
