# Architecture and dependencies

`DeckCore` owns profile contracts, parsing, input leases, grid geometry and local RPC framing. `DesktopDeck` owns each VNC worker, system-SSH child, terminal and UI lifetime. `CVNC` adapts the unmodified LibVNCClient C API. One serial worker per VNC connection owns protocol access; UI delivery permits at most one pending frame. Input batches have finite capacity, and stale generations are rejected. `DeckMCP` uses the official Swift SDK and relays requests to the app's owner-only Unix socket. At most eight RPC requests are active at once; messages are capped at 24 MiB.

Source dependencies: LibVNCServer 0.9.15 (client target only), TurboVNC 3.3.1 (unmodified public-domain Unicode/X11 keysym converter and compatibility reference), SwiftTerm 1.99.3 and MCP Swift SDK 0.12.1. Advance upstream pins deliberately, review their changes and license notices, rebuild, and rerun the affected checks. Do not patch vendored protocol or terminal implementations to work around UI defects.

The C adapter contains a narrow compatibility fix for LibVNCClient 0.9.15 desktop-size requests: it initializes all screen geometry fields and preserves the server-advertised screen ID using the library's public protocol types and transport. The upstream sender leaves those fields uninitialized. Requested resolution is accepted by the UI only after the actual framebuffer changes; unsupported/rejected/unconfirmed requests remain visible. Other connected viewers share the server's desktop resolution.

Keyboard text uses the pinned TurboVNC converter: standard X11 character keysyms are preferred, with direct Unicode keysyms for characters outside the legacy table. Native keyboard events and MCP text share this converter. This avoids allocating redundant Unicode aliases for characters that the X11 keyboard map already represents.

The adapter also advertises bounded UTF-8 clipboard receive capabilities after upstream recognizes server support. LibVNCClient 0.9.15 decodes provided text but does not complete that capability reply. The adapter requests unsolicited text up to a 1 MB text limit with room for compression overhead inside upstream’s 1 MiB message limit; the upstream source remains unchanged.

The app is GPL-3.0-or-later. Upstream copyright/license notices remain with their sources. Bundled native and Swift dependencies retain their own licenses; the build includes their notices under Resources/Licenses.

The app icon is generated with the built-in imagegen tool. Its editable source asset is `Resources/AppIcon-source.png`; the prompt is recorded in `Resources/AppIcon.prompt.txt`. The build deterministically generates standard macOS icon sizes and the plugin icon from that asset.

The native video surface accepts the exact proposed viewport size and redraws on frame/drawable resizing. Workspace content width is explicitly bounded by the window minus the visible sidebar and divider. `connections_list.viewState` exposes read-only local zoom/pan and viewport/visible dimensions; `attached` identifies the active interactive surface. Reusing a native surface clears the previous session binding and textures.

When a narrow window cannot fit every toolbar control, the single toolbar row scrolls horizontally instead of forcing the video canvas beyond its allocated width.

Human navigation creates one ephemeral keyboard-focus request for the selected profile and optional terminal tab. Native surfaces fulfill it after attachment; later renders cannot replay it. Selection changes, another text editor, a sheet or an inactive window cancel pending focus. The local RPC reports the last request result as `keyboardFocus` and the current responder ownership as `viewState.focused`, allowing verification without sending keys.
