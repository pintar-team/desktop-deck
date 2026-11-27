import Foundation
import AppKit
import Darwin
import DeckCore

final class ControlServer: @unchecked Sendable {
    private let fd: Int32
    private let slots=DispatchSemaphore(value:8)
    private weak var model: WorkspaceModel?
    private var running=true
    private let lock=NSLock()
    @MainActor init(model: WorkspaceModel) throws {
        self.model=model
        try FileManager.default.createDirectory(at:LocalRPC.directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        var metadata=stat()
        guard lstat(LocalRPC.directory.path,&metadata)==0,metadata.st_uid==getuid(),metadata.st_mode & S_IFMT == S_IFDIR else { throw DeckError("Unsafe control directory") }
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:LocalRPC.directory.path)
        if let existing=try? LocalRPC.connect() { close(existing); throw DeckError("Another Desktop Deck instance owns the control socket") }
        if lstat(LocalRPC.socketPath,&metadata)==0 {
            guard metadata.st_uid==getuid(),metadata.st_mode & S_IFMT == S_IFSOCK else { throw DeckError("Refusing to replace foreign control path") }
            unlink(LocalRPC.socketPath)
        }
        var addr=try LocalRPC.address(LocalRPC.socketPath);fd=socket(AF_UNIX,SOCK_STREAM,0)
        let result=withUnsafePointer(to:&addr) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { bind(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result==0,chmod(LocalRPC.socketPath,0o600)==0,listen(fd,8)==0 else { close(fd); throw DeckError("Cannot start local control server") }
        DispatchQueue.global(qos:.utility).async { [self] in acceptLoop() }
    }
    private func acceptLoop() {
        while true {
            lock.lock(); let active=running; lock.unlock(); if !active { return }
            let client=accept(fd,nil,nil); if client<0 { continue }
            var uid: uid_t=0,gid: gid_t=0
            guard getpeereid(client,&uid,&gid)==0,uid==getuid(),LocalRPC.configureStream(client),slots.wait(timeout:.now()) == .success else { close(client); continue }
            DispatchQueue.global(qos:.utility).async { [self] in
                do {
                    let request=try JSONSerialization.jsonObject(with:LocalRPC.read(fd:client)) as? [String:Any] ?? [:]
                    Task { @MainActor [self] in
                        let result: [String:Any]
                        do { guard let model=self.model else { throw DeckError("App is closing") }; result=try await model.handle(request) }
                        catch { result=["error":error.localizedDescription] }
                        DispatchQueue.global(qos:.utility).async { [self] in
                            if let data=try? JSONSerialization.data(withJSONObject:result),data.count<LocalRPC.maxBytes { try? LocalRPC.write(data,fd:client) }
                            else { try? LocalRPC.write(Data("{\"error\":\"Response too large; capture a smaller region\"}".utf8),fd:client) }
                            close(client); slots.signal()
                        }
                    }
                } catch { close(client); slots.signal() }
            }
        }
    }
    func stop() { lock.lock(); defer { lock.unlock() }; guard running else { return }; running=false; shutdown(fd,SHUT_RDWR); close(fd); unlink(LocalRPC.socketPath) }
}

@MainActor extension WorkspaceModel {
    func handle(_ request: [String:Any]) async throws -> [String:Any] {
        let tool=request["tool"] as? String ?? "",a=request["arguments"] as? [String:Any] ?? [:]
        let client=request["client"] as? String ?? ""
        guard !client.isEmpty,ToolDefinitions.all.contains(where:{$0.name==tool}) else { throw DeckError("Unknown tool or missing client") }
        func string(_ key: String) -> String { a[key] as? String ?? "" }
        func int(_ key: String,_ fallback: Int=0) -> Int { a[key] as? Int ?? fallback }
        func double(_ key: String,_ fallback: Double) -> Double { a[key] as? Double ?? fallback }
        func session() throws -> DesktopSession {
            guard let s=sessions.first(where:{$0.id.uuidString.caseInsensitiveCompare(string("profile")) == .orderedSame}) else { throw DeckError("Unknown profile ID") }; return s
        }
        func terminal() throws -> TerminalTab {
            guard let t=sessions.flatMap(\.terminals).first(where:{$0.id.uuidString.caseInsensitiveCompare(string("terminal")) == .orderedSame}) else { throw DeckError("Unknown terminal ID") }; return t
        }
        func terminalInfo(_ t: TerminalTab) -> [String:Any] { ["id":t.id.uuidString,"title":t.title,"status":t.status,"persistent":t.persistent,"generation":t.generation,"timing":t.view.timing.snapshot,"viewState":["attached":t.view.window != nil,"focused":t.view.ownsKeyboardFocus,"width":t.view.bounds.width,"height":t.view.bounds.height]] }
        switch tool {
        case "profiles_manage":return try manageProfiles(a)
        case "workspace_transfer":return try transferConfiguration(a)
        case "connections_list": return ["version":"0.3.12","keyboardFocus":keyboardFocusRequest?.status ?? "idle","window":WindowLayout.info(NSApp.mainWindow),"profiles":sessions.map { s in
            ["id":s.id.uuidString,"name":s.profile.name,"state":s.state,"detail":s.detail,"generation":s.connectionRevision,"geometry":s.geometry,"width":s.frame?.width ?? 0,"height":s.frame?.height ?? 0,"ssh":s.profile.usesSSH,"vnc":s.profile.hasVNC,"sessionManager":s.profile.sessionManager,"quality":s.profile.quality,"view":s.surfaceMode,"viewState":s.viewState,"resolutionStatus":s.resolutionStatus,"attempt":s.attemptNumber,"maxAttempts":ConnectionLimits.attempts,"retryIn":s.retryCountdown,"lastError":s.lastError,"hostMetrics":s.hostMetrics?.rpc ?? [:],"metricsError":s.hostMetricsError,"activity":s.activity.map{["perSecond":$0.perSecond,"unit":$0.unit,"segments":$0.segments] as [String:Any]} ?? [:]] as [String:Any]
        }]
        case "connection_control":
            let s=try session(); switch string("action") {case "connect":connectIfNeeded(s);case "reconnect":connect(s);case "disconnect":disconnect(s);default:throw DeckError("Expected connect, disconnect or reconnect")};return ["state":s.state]
        case "sessions_list":
            let s=try session(); guard s.profile.sessionManager else { throw DeckError("Session Manager not configured") }
            let remote=try await Commands.list(s.profile); s.remoteSessions=remote
            return ["sessions":remote.map{["display":$0.display,"pid":$0.pid] as [String:Any]}]
        case "session_select":
            let s=try session();guard s.profile.sessionManager else {throw DeckError("Session Manager not configured")}
            let remote=try await Commands.list(s.profile)
            guard remote.contains(where:{$0.display==string("display")}) else { throw DeckError("Display not present") }
            s.remoteSessions=remote;selectSession(s,display:string("display"));return ["display":s.profile.display]
        case "session_create":
            let s=try session(); guard s.profile.sessionManager else { throw DeckError("Session Manager not configured") }
            try await createSession(s); return ["display":s.profile.display]
        case "screen_capture":
            let s=try session(); let crop=a["width"] != nil ? CGRect(x:int("x"),y:int("y"),width:int("width"),height:int("height")) : nil
            return ["image":try s.screenshot(crop).base64EncodedString(),"generation":s.connectionRevision,"geometry":s.geometry,"width":s.frame?.width ?? 0,"height":s.frame?.height ?? 0,"connected":s.active,"capturedAt":s.frame?.time.timeIntervalSince1970 ?? 0,"cropX":int("x"),"cropY":int("y")]
        case "clipboard":
            let s=try session()
            switch string("action") {
            case "read":return ["text":s.remoteClipboard ?? "","available":s.remoteClipboard != nil,"generation":s.connectionRevision,"geometry":s.geometry,"pending":s.clipboardInFlight,"status":s.clipboardStatus]
            case "write":
                try s.lease.acquire(client)
                try s.lease.validate(client,generation:s.connectionRevision,expectedGeneration:int("generation",-1),geometry:s.geometry,expectedGeometry:int("geometry",-1),connected:s.active)
                try s.sendClipboard(string("text"),pasteKeys:a["paste"] as? Bool == true ? [0xffe3,0x76]:nil,human:false)
                return ["accepted":true,"completion":"clipboard transfer queued"]
            default:throw DeckError("Expected clipboard read or write")
            }
        case "screen_input":
            let s=try session(); try s.lease.acquire(client)
            try s.lease.validate(client,generation:s.connectionRevision,expectedGeneration:int("generation",-1),geometry:s.geometry,expectedGeometry:int("geometry",-1),connected:s.active)
            let x=int("x",s.lastPoint.0),y=int("y",s.lastPoint.1),button=int("button",1)
            guard (1...3).contains(button),x>=0,y>=0,x<(s.frame?.width ?? 0),y<(s.frame?.height ?? 0) else { throw DeckError("Input outside framebuffer or invalid button") }
            switch string("action") {
            case "move": s.pointer(x,y,s.mask)
            case "click": let original=s.mask;s.pointer(x,y,original | (1<<(button-1)));s.pointer(x,y,original)
            case "down": s.pointer(x,y,s.mask | (1<<(button-1)))
            case "up": s.pointer(x,y,s.mask & ~(1<<(button-1)))
            case "scroll": s.scroll(x, y, steps: int("delta"))
            case "key": guard let key=UInt32(exactly:int("key")) else { throw DeckError("Invalid keysym") }; s.key(key,down:a["down"] as? Bool ?? true)
            case "text": guard string("text").utf8.count<=4096 else { throw DeckError("Text exceeds 4096 bytes") }; try s.text(string("text"))
            default: throw DeckError("Unknown input action")
            }; return ["accepted":true,"completion":"input queued"]
        case "screen_view":
            let s=try session()
            let mode=string("mode")
            if !mode.isEmpty {
                guard let selection=ViewMode(rawValue:mode),s.profile.supports(selection) else {throw DeckError("Unsupported surface mode")}
            }
            updateWorkspace { if !$0.profiles.contains(s.id) {$0.profiles.append(s.id)}; $0.focused=s.id; $0.focusMode=true }
            if let selection=ViewMode(rawValue:mode) {setViewMode(selection)}
            if a["width"] != nil || a["height"] != nil {try s.requestResolution(width:int("width"),height:int("height"))}
            if a["zoom"] != nil {s.zoom=min(8,max(0.25,double("zoom",s.zoom)))};s.pan=CGPoint(x:double("panX",s.pan.x),y:double("panY",s.pan.y));return ["zoom":s.zoom]
        case "terminals_list": return ["terminals":try session().terminals.map(terminalInfo)]
        case "terminal_open":
            let s=try session(); guard s.profile.usesSSH else { throw DeckError("SSH not configured") }
            return terminalInfo(openTerminal(s,focusKeyboard:false))
        case "terminal_read":
            let t=try terminal(); let full=t.read(limit:65536),limit=min(65536,max(1,int("limit",16000)))
            let text=String(full.suffix(limit))
            return ["terminal":t.id.uuidString,"generation":t.generation,"text":text,"truncated":full.count>limit,"cursor":t.outputRevision,"changed":int("cursor",-1) != t.outputRevision,"status":t.status,"persistent":t.persistent,"columns":t.view.terminalDimensions.cols,"rows":t.view.terminalDimensions.rows]
        case "terminal_input":
            let t=try terminal(); try t.lease.acquire(client)
            try t.lease.validate(client,generation:t.generation,expectedGeneration:int("generation",-1),geometry:0,expectedGeometry:0,connected:t.isOnline)
            let value: String
            switch string("key") { case "": value=string("text"); case "Enter": value="\r"; case "Ctrl-C": value="\u{03}"; default: throw DeckError("Supported terminal keys: Enter, Ctrl-C") }
            guard value.utf8.count<=65536 else { throw DeckError("Input too large") }; t.send(value); return ["accepted":true,"completion":"input sent; command status unknown"]
        case "terminal_control":
            let t=try terminal(); switch string("action") { case "reconnect": t.detach(); t.connect(); case "detach": t.detach(); case "end": try await t.end(); default: throw DeckError("Expected reconnect, detach or end") }; return terminalInfo(t)
        default: throw DeckError("Unsupported tool")
        }
    }
}
