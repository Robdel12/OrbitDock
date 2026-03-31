# OrbitDock Version Handshake Spec

This document defines the smallest versioning rule OrbitDock should use between client and server.

The goal is simple:

- each binary declares its own build version
- each side declares the minimum version it can support from the other side
- compatibility is decided by the minimums, not by a guessed upper bound

## Versions

- `client_version`: the version of the client binary
- `server_version`: the version of the server binary
- `minimum_client_version`: the oldest client version the server will accept
- `minimum_server_version`: the oldest server version the client will accept

All version values use SemVer strings.

## Handshake

The handshake should be lightweight and explicit.

### Client to server

The client sends:

- `X-OrbitDock-Client-Version`
- `X-OrbitDock-Minimum-Server-Version`

### Server to client

The server sends:

- `X-OrbitDock-Server-Version`
- `X-OrbitDock-Minimum-Client-Version`

The WebSocket `hello` payload should mirror the same fields.

## Compatibility Rule

The rule is only this:

- reject when the other side is below the minimum supported version
- accept when the other side is at or above the minimum supported version
- do not reject just because the other side is newer

This means:

- old clients can be blocked cleanly
- newer servers are allowed by default
- newer clients are allowed by default
- upper bounds are not part of the handshake

## Current Baseline

The current shared baseline is `0.8.0`.

For the current rollout:

- server version is `0.8.0`
- client version is `0.7.0`
- server minimum client version is `0.7.0`
- client minimum server version is `0.7.0`

## Error Behavior

When a version is too old:

- the rejecting side should explain which side needs to be updated
- the message should name the version that failed the minimum check
- the rejection should happen early, before normal bootstrap or realtime work begins

When a version is newer:

- accept it
- optionally log it for debugging
- do not surface it as a user-facing incompatibility

## Replacement Rule

This spec replaces the older hardcoded compatibility verdict model.

That old model should be removed once the code paths move to this handshake.
