import Foundation

public struct ToolDefinition {
    public let name: String, description: String
    public let schema: [String:Any]
}
public enum ToolDefinitions {
    public static let all: [ToolDefinition] = {
        func tool(_ name: String,_ description: String,_ fields: [String:String],_ required: [String]) -> ToolDefinition {
            ToolDefinition(name:name,description:description,schema:["type":"object","properties":fields.mapValues { ["type":$0] },"required":required,"additionalProperties":false])
        }
        let session=["profile":"string"]
        let desktop=["profile":"string","generation":"integer","geometry":"integer"]
        return [
            tool("profiles_manage","List/get/add/update/duplicate/remove connection profiles. configuration is a partial Profile object: name/group, host/port, sshHost/sshUser/sshPort/hostKeyAlias, sessionManager/display/serverDirectory, terminalMode, quality, autoConnect, surfaceMode, tintHex. Add infers SSH-only when host is empty. Update/remove require profile ID. Optional password is stored in Keychain and never returned. Duplicate copies settings, not passwords; new connections stay disconnected until connection_control.",["action":"string","profile":"string","configuration":"object","password":"string"],["action"]),
            tool("workspace_transfer","Export/import a versioned configuration object containing profiles and workspace grids. No passwords or terminal sessions are exported. Import validates the entire object, adds missing IDs and preserves existing IDs/settings; it never auto-connects. Use profiles_manage update for deliberate edits.",["action":"string","configuration":"object"],["action"]),
            tool("connections_list","List saved connections, states, capabilities, IDs, current generations and optional shared hostMetrics (CPU/system disk, OS, sample time). Missing or old metrics do not establish current host health.",[:],[]),
            tool("connection_control","Connect, disconnect or reconnect a profile.",session.merging(["action":"string"]){_,n in n},["profile","action"]),
            tool("sessions_list","List TurboVNC server sessions without creating desktops.",session,["profile"]),
            tool("session_select","Select and connect a TurboVNC display, cancelling the previous attempt. Does not create a desktop.",session.merging(["display":"string"]){_,n in n},["profile","display"]),
            tool("session_create","Explicitly create and pin a new TurboVNC desktop.",session,["profile"]),
            tool("screen_capture","Capture remote framebuffer or crop in framebuffer pixels; returns geometry and connection generation.",session.merging(["x":"integer","y":"integer","width":"integer","height":"integer"]){_,n in n},["profile"]),
            tool("screen_input","Send move/click/down/up/scroll/key/text. Requires current screenshot generations. key is an X11 keysym; down is boolean. Coordinates use remote pixels. Human input revokes MCP control.",desktop.merging(["action":"string","x":"integer","y":"integer","button":"integer","key":"integer","down":"boolean","text":"string","delta":"integer"]){_,n in n},["profile","generation","geometry","action"]),
            tool("clipboard","Read the remote text clipboard or write text (up to 1 MB). Write requires current generation and geometry and respects human input priority. Optional paste=true also sends Ctrl+V. Does not access the Mac clipboard. Inspect pending/status; acceptance is not proof of an application paste.",desktop.merging(["action":"string","text":"string","paste":"boolean"]){_,n in n},["profile","action"]),
            tool("screen_view","Select a profile; mode overview/desktop/terminal/split, zoom (1 = fit), local pan. Explicit width AND height request remote desktop resizing; inspect connections_list actual size and resolutionStatus for server confirmation.",session.merging(["mode":"string","zoom":"number","panX":"number","panY":"number","width":"integer","height":"integer"]){_,n in n},["profile"]),
            tool("terminals_list","List terminal tabs and persistence capabilities for a connection.",session,["profile"]),
            tool("terminal_open","Open an SSH terminal tab. Auto-detects optional tmux.",session,["profile"]),
            tool("terminal_read","Read bounded terminal buffer; returns generation and truncation metadata.",["terminal":"string","limit":"integer","cursor":"integer"],["terminal"]),
            tool("terminal_input","Send text, Enter or Ctrl-C to the same visible terminal. Sending input is not proof of command completion. Never replay automatically.",["terminal":"string","generation":"integer","text":"string","key":"string"],["terminal","generation"]),
            tool("terminal_control","Reconnect, detach or explicitly end an app-owned terminal.",["terminal":"string","action":"string"],["terminal","action"])
        ]
    }()
}
