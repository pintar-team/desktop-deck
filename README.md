# Desktop Deck

A native macOS workspace for VNC desktops and SSH terminals, with local MCP tools for Codex and Claude Code.

- Continuous grids: fit every desktop, or choose 2, 3, 4 or 5 columns.
- Saved workspaces, per-connection colors, a focus view and an optional filmstrip.
- Automatic reconnect with bounded attempts and inline status.
- Full-window SSH terminals or a resizable split view; tmux is optional.
- Clipboard transfer, keyboard shortcuts, zoom and explicit remote resolution control.
- Compact host CPU/disk metrics over SSH.
- 16 MCP tools for profiles, workspaces, screenshots, input and shared terminal tabs.

Desktop Deck uses unmodified upstream libraries for VNC decoding and terminal emulation. TurboVNC Session Manager is optional; direct VNC and plain SSH work independently.

## Download for Mac

Download the **DMG** from [GitHub Releases](https://github.com/pintar-team/desktop-deck/releases/latest), open it, and drag **Desktop Deck.app** into **Applications**. A ZIP containing the same app is also available. No Xcode, Homebrew or compilation is needed to run it.

Requires **Apple Silicon (M1 or later)** and **macOS 26 or later**. Intel Macs and earlier macOS versions are not supported by this binary.

The app is ad-hoc signed and has not been notarized by Apple. If macOS blocks the first launch, follow [Apple's instructions](https://support.apple.com/en-us/102445) for **System Settings → Privacy & Security → Open Anyway** after checking the download's origin. SHA-256 checksums and a source/dependency manifest accompany each release.

## Build requirements

- Apple Silicon Mac running macOS 26 or later.
- Xcode 26 or later, command-line tools selected and the Xcode license accepted.
- CMake, Ninja, libjpeg-turbo and OpenSSL 3.
- Python 3 for packaging and the MCP smoke check.

The current build targets arm64/macOS 26 and uses static Homebrew libraries.

## Build and install

```sh
git clone --recurse-submodules https://github.com/pintar-team/desktop-deck.git
cd desktop-deck
brew install cmake ninja jpeg-turbo openssl@3
bash scripts/build.sh release
mkdir -p "$HOME/Applications"
ditto 'dist/Desktop Deck.app' "$HOME/Applications/Desktop Deck.app"
open "$HOME/Applications/Desktop Deck.app"
```

For an existing checkout, run `git submodule update --init` before building. The build defaults to `/opt/homebrew/opt/jpeg-turbo` and `/opt/homebrew/opt/openssl@3`; set `JPEG_PREFIX` and `OPENSSL_PREFIX` to use other installations. Native libraries, Swift resources and dependency license notices are included in the app bundle.

## Connect

Add a connection from the sidebar. Fill in **SSH** for terminals, **VNC** for a desktop, or both for a tunneled desktop and terminal tabs. Advanced fields are optional overrides. SSH uses your existing configuration, keys, ssh-agent and verified host keys.

Click a preview to control it. Use the toolbar to switch between Overview, Desktop, Terminal and Split. The sidebar and filmstrip are independent toggles. Workspace tabs appear when more than one workspace exists.

| Shortcut | Action |
| --- | --- |
| Command-Shift-G | Overview / focused connection |
| Command-Shift-T | Desktop / terminal |
| Command-Shift-I | Toolbar auto-hide |
| Control-Command-F | Native full screen |

See the [usage guide](docs/usage.md) for grids, reconnect, clipboard, metrics, Session Manager and terminal persistence.

## Codex and Claude Code

Build the app first, then install either plugin or both through the clients' supported CLI commands:

```sh
bash scripts/install.sh both       # or codex / claude
open "$HOME/Applications/Desktop Deck.app"
python3 scripts/check-mcp.py
```

The installer copies the app to `~/Applications` and registers the checkout as a local plugin marketplace. Keep the checkout available while using that marketplace. It preserves unrelated client configuration and does not restart chats. Load the plugin in a new chat or through the client's supported reload, then call `connections_list` to verify access.

Both plugins use the bundled stdio MCP server and the same running app. No network MCP listener is opened. Human input takes priority; screenshots carry generation/geometry guards, and reconnect never replays input. Terminal input acceptance is delivery, not proof of command completion. Read the [plugin control skill](plugins/desktop-deck/skills/control/SKILL.md) before automation.

To uninstall a plugin:

```sh
codex plugin remove desktop-deck@desktop-deck-local
claude plugin uninstall desktop-deck@desktop-deck-local
```

## Personal data

Profiles and workspace layouts stay in `~/Library/Application Support/DesktopDeck`; VNC passwords stay in Keychain. SSH credentials remain in your existing SSH setup. The repository and plugins contain no saved connections or credentials.

Configuration export includes server addresses, account names and workspace settings, but excludes passwords and terminal sessions. Treat exports, screenshots, clipboard contents and terminal output as private data. The Git ignore rules help keep local artifacts out of commits; review changes before publishing them.

The local MCP socket is restricted to the current OS user. Agents using the plugin can operate connections available to the app; the target's normal authorization rules still apply.

## Checks

After building the native dependencies:

```sh
swift test --jobs 4
python3 scripts/check-mcp.py
```

The MCP smoke check requires the app to be open and sends no remote input. Unit tests cover parsing, layouts, profile/archive contracts, input guards, reconnect policy and host metrics. Endpoint-specific acceptance scripts and fixtures are maintained outside this repository; they are not required to build or run the app.

Linux host metrics and macOS probes have been exercised live. The Windows PowerShell/CIM collector has not yet been tested on a live Windows host. Direct VNC security types and server-specific extensions vary; inspect reported errors and capabilities.

See [architecture and dependencies](docs/architecture.md) for pinned upstream versions, ownership boundaries and compatibility adapters.

Maintainers: see [release packaging](docs/releases.md) for the standalone ZIP/DMG recipe.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE). Bundled dependencies retain their own licenses and notices.
