# Desktop Deck

Build a universal macOS VNC/SSH workspace. Keep protocol decoding and terminal emulation in pinned upstream libraries. UI and MCP must share connection state, input guards, framebuffers and terminal sessions.

- Never put private host addresses, account names, saved desktop bindings or credentials in source, tests, docs, plugin packages or commits. Personal profiles belong only in the application's private state directory; secrets belong in Keychain or the existing SSH setup.
- Fixture generators and endpoint-specific acceptance scripts live outside this repository. Do not add private live-test configuration to public tests. Keep compact redacted results and recoverable commands only.
- Use `bash scripts/build.sh release`, `swift test --jobs 4`, and the read-only MCP smoke check. Test runtime changes against authorized real endpoints using isolated app-owned resources; preserve active remote desktops and user work.
- Capture a fresh screenshot/geometry after reconnect or resize before sending input. Never replay input after reconnect. Human input has priority. Input acceptance is not command completion.
- tmux is optional. Plain SSH and direct VNC remain supported without server-specific assumptions. New server sessions and ending remote terminals require explicit actions.
- Keep resource ownership explicit, queues and output bounded, cancellation finite, and failure state visible without modal reconnect dialogs. Do not edit upstream sources for application UI fixes.
- Run code-duplication-audit Type 1 and Type 2 on owned source/tests, separately from dependencies; report coverage and redundancy. Also review lifetime, cancellation, backpressure and responsibility boundaries.
