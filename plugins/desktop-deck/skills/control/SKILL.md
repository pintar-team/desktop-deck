---
name: control
description: Use Desktop Deck to inspect or operate connected VNC screens and shared SSH terminals when the user requests remote computer or terminal work.
---

Use the Desktop Deck MCP tools. Open the macOS app first. List connections to obtain stable IDs and capabilities; do not infer identity from a tile's position or name alone.

connections_list includes optional hostMetrics with os, sampledAt, cpuPercent and system-disk available/total bytes, usage percentage and path. Missing fields mean unavailable; check the timestamp and metricsError before using a sample. These are shared host measurements, not per-agent process usage. Monitoring is read-only and independent of VNC connection health.

Use profiles_manage to add, inspect, edit or duplicate saved connections. A profile with only sshHost is terminal-only; host provides VNC; Session Manager additionally requires SSH. User, host-key alias and installation directory are optional overrides. New/duplicated profiles do not connect automatically. Passwords are accepted separately into Keychain and never returned or copied to duplicates. Do not log them. Configuration edits can disconnect the changed VNC target; existing terminal tabs retain their original endpoint binding. Use workspace_transfer for versioned profile/grid import and export. Imports validate before mutation and preserve existing IDs/settings; use explicit update for changes. Remove a profile only when the user requests that deletion.

For VNC input, capture the screen first. Use the returned connection generation and geometry revision on every input call. Coordinates are original remote framebuffer pixels; crop origins must be added. After reconnect or resize, capture again. A cached image can be stale: check connected and capturedAt.

Human input takes priority. If INPUT_BUSY, wait for the user to release control; do not retry a click in a loop. On STALE_SESSION, inspect again. Never replay a failed input sequence after reconnect.

The clipboard tool reads/writes only the remote text clipboard. Obtain current generation and geometry before a write. Inspect pending/status and the receiving application before reporting completion; paste=true sends Ctrl+V after transfer, without proving that the application used the text. The tool does not read or modify the Mac clipboard. Text is bounded to 1 MB; legacy servers can reject characters outside Latin-1. Do not log clipboard contents or replay clipboard writes after reconnect.

Terminal tabs are shared with the human. Open or select a tab, read its output and generation, then send input. Sending text does not press Enter. Send terminal_input key Enter separately when execution is intended. The accepted result proves input delivery only, not command completion or successful chat submission. Read the output to establish the result. Use bounded reads and output cursors. Never resend a command automatically after a connection failure.

tmux is optional. persistent=true permits reattachment; plain SSH may lose the shell and its commands on disconnect. Creation of a VNC desktop and ending a terminal require an explicit user task. Ordinary disconnect/detach preserves remote VNC desktops and persistent terminals.

Honor the target project's established messaging and administrative workflows. Desktop control does not supersede project-specific authorization or delivery verification.
