# OrbitDockCore

Shared Swift package used by the OrbitDock app.

## Scope

- Shared models and utilities for the macOS app target.
- No hook CLI executable lives in this package.

Claude hook transport is handled by the Rust binary:

```bash
orbitdock-server install-hooks
```

That command installs Claude hooks that call:

```bash
orbitdock-server hook-forward <event-type>
```
