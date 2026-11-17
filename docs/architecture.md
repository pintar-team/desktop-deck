# Architecture and dependencies

`DeckCore` owns profile contracts, parsing, input leases, grid geometry and local RPC framing. `DesktopDeck` owns each VNC worker, system-SSH child, terminal and UI lifetime. `CVNC` adapts the unmodified LibVNCClient C API. One serial worker per VNC connection owns protocol access; UI delivery permits at most one pending frame. Input batches have finite capacity, and stale generations are rejected. `DeckMCP` uses the official Swift SDK and relays requests to the app's owner-only Unix socket. At most eight RPC requests are active at once; messages are capped at 24 MiB.

Source dependencies: LibVNCServer 0.9.15 (client target only), TurboVNC 3.3.1 (compatibility reference, not linked), SwiftTerm 1.99.3 and MCP Swift SDK 0.12.1. Advance upstream pins deliberately, review their changes and license notices, rebuild, and rerun the affected checks. Do not patch vendored protocol or terminal implementations to work around UI defects.

The C adapter contains a narrow compatibility fix for LibVNCClient 0.9.15 desktop-size requests: it initializes all screen geometry fields and preserves the server-advertised screen ID using the library's public protocol types and transport. The upstream sender leaves those fields uninitialized. Requested resolution is accepted by the UI only after the actual framebuffer changes; unsupported/rejected/unconfirmed requests remain visible. Other connected viewers share the server's desktop resolution.

The adapter also advertises bounded UTF-8 clipboard receive capabilities after upstream recognizes server support. LibVNCClient 0.9.15 decodes provided text but does not complete that capability reply. The adapter requests unsolicited text up to a 1 MB text limit with room for compression overhead inside upstream’s 1 MiB message limit; the upstream source remains unchanged.

The app is GPL-3.0-or-later. Upstream copyright/license notices remain with their sources. Bundled native and Swift dependencies retain their own licenses; the build includes their notices under Resources/Licenses.

The app icon is generated with the built-in imagegen tool. Its editable source asset is `Resources/AppIcon-source.png`; the prompt is recorded in `Resources/AppIcon.prompt.txt`. The build deterministically generates standard macOS icon sizes and the plugin icon from that asset.
