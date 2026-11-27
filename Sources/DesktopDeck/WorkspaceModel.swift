import AppKit
import SwiftUI
import DeckCore
import Network
import Combine
import CVNC

@MainActor final class DesktopSession: ObservableObject, Identifiable {
    let id: UUID
    @Published var profile: Profile
    @Published var phase=ConnectionPhase.disconnected
    @Published var attemptNumber=0
    @Published var retryCountdown=0
    @Published var lastError=""
    var attemptSerial=0
    var retryAt: Date?
    var connectedAt: Date?
    @Published var previousDisplay: String?
    @Published var remoteClipboard: String?
    @Published var clipboardStatus="Idle"
    @Published var heldModifiers=Set<UInt32>()
    @Published var feedback: FeedbackNotice?
    weak var inputView: RemoteMetalView?
    var clipboardInFlight=false
    @Published var imageUploading=false
    var imageTransfer: Task<Void,Never>?
    var imageTransferID: UUID?
    var humanActionRevision=0
    var clipboardPasteKeys: [UInt32]?
    var clipboardFeedback="Clipboard sent"
    var copyFeedbackIntent=CopyFeedbackIntent()
    var selectedTab: TerminalTab? {terminals.first{$0.id==selectedTerminal}}
    var state: String {
        if profile.hasVNC {return phase.label}
        return isOnline ? "Connected":(selectedTab?.status ?? "Disconnected")
    }
    var indicator: ConnectionIndicator {profile.hasVNC ? phase.indicator:(selectedTab?.connection.indicator ?? .offline)}
    var isOnline: Bool {indicator == .online}
    var wantsConnection: Bool {profile.hasVNC ? desired:(selectedTab?.desired ?? false)}
    var connectionSummary: String {
        if !profile.hasVNC {return state}
        if phase == .backoff {return "Retry \(attemptNumber+1)/\(ConnectionLimits.attempts) in \(retryCountdown)s"}
        if desired && !active && attemptNumber>0 {return "\(state) · \(attemptNumber)/\(ConnectionLimits.attempts)"}
        return state
    }
    @Published var detail=""
    @Published var hostMetrics: HostMetrics?
    @Published var hostMetricsError=""
    private var activitySampler=ActivitySampler()
    @Published private var sampledActivity: ActivityReading?
    private var activitySource: ActivitySource? {
        guard isOnline else {return nil}
        if profile.hasVNC {return .desktop(connectionRevision)}
        return selectedTab.map { .terminal($0.id,$0.generation) }
    }
    var activity: ActivityReading? {sampledActivity?.source == activitySource ? sampledActivity:nil}
    func sampleActivity(at now: TimeInterval) {
        let source=activitySource
        let total: UInt64?
        switch source {
        case .desktop: total=worker?.receivedBytes
        case .terminal: total=selectedTab.map { UInt64($0.outputRevision) }
        case nil: total=nil
        }
        let next=activitySampler.sample(source:source,total:total,at:now)
        if next != sampledActivity {sampledActivity=next}
    }
    @Published var frame: Frame?
    @Published var geometry=0
    @Published var generation=0
    var connectionRevision=0
    @Published var zoom=1.0
    @Published var pan=CGPoint.zero
    @Published var terminals=[TerminalTab]()
    var terminalObservations=[UUID:AnyCancellable]()
    @Published var selectedTerminal: UUID?
    @Published var surfaceMode="desktop"
    @Published var terminalHeight: CGFloat=260
    @Published var remoteSessions=[RemoteSession]()
    @Published var resolutionStatus=""
    var pendingResolution: (Int,Int)?
    private var resizeRequest=0
    var desired=false, needsAction=false
    var lease=InputLease()
    var worker: VNCWorker?
    var tunnel: SSHTunnel?
    var task: Task<Void,Never>?
    var pressed=Set<UInt32>()
    var mask=0
    var lastPoint=(0,0)
    var lastFrameTime=Date.distantPast
    var adaptiveQuality=7
    var qualityChanged=Date.distantPast
    var viewport=CGSize(width:1000,height:700)
    init(_ profile: Profile) { self.profile=profile; id=profile.id; surfaceMode=profile.surfaceMode ?? "desktop" }
    var active: Bool {profile.hasVNC && phase == .connected}
    var tint: Color {DeckTheme.color(profile.tintHex ?? profile.autoTintHex ?? DeckTheme.palette[0].hex)}
    var tooltip: String {
        let summary=connectionSummary
        var lines=["\(profile.name) · \(summary)"]
        let details=profile.hasVNC ? [detail,active ? "":lastError]:[selectedTab?.status ?? ""]
        for item in details.map({$0.trimmingCharacters(in:.whitespacesAndNewlines)}) where !item.isEmpty && item != summary && !lines.contains(item) {lines.append(item)}
        return lines.joined(separator:"\n")
    }
    func humanInput(invalidatePendingPaste: Bool=true) {if invalidatePendingPaste {humanActionRevision += 1};if lease.owner != nil {releaseInput()}; lease.human() }
    func releaseInput() {
        for key in pressed { worker?.enqueue(.key(key,false)) }; pressed.removeAll()
        heldModifiers.removeAll()
        if mask != 0 {mask=0;worker?.enqueue(.pointer(lastPoint.0,lastPoint.1,0))}
    }
    func key(_ value: UInt32,down: Bool) {
        guard active else { return }
        if down,(value==0x63 || value==0x43),pressed.contains(0xffe3) {copyFeedbackIntent.request()}
        if down { pressed.insert(value) } else { pressed.remove(value) }
        worker?.enqueue(.key(value,down))
    }
    func pointer(_ x: Int,_ y: Int,_ buttons: Int) {
        guard active,let frame,x>=0,y>=0,x<frame.width,y<frame.height else { return }
        mask=buttons; lastPoint=(x,y); worker?.enqueue(.pointer(x,y,buttons))
    }
    func scroll(_ x: Int, _ y: Int, steps: Int) {
        guard steps != 0, active, let frame, x >= 0, y >= 0, x < frame.width, y < frame.height else { return }
        let wheelMask = mask | (steps > 0 ? 8 : 16)
        let detent: [VNCWorker.Event] = [.pointer(x, y, wheelMask), .pointer(x, y, mask)]
        let events = Array(repeating: detent, count: Int(min(steps.magnitude, 40))).flatMap { $0 }
        if worker?.enqueueBatch(events) == true { lastPoint = (x, y) }
    }
    func text(_ text: String) throws {
        var commands=[VNCWorker.Event]()
        for scalar in text.unicodeScalars {
            let key: UInt32=scalar.value==10 ? 0xff0d : deck_vnc_keysym(scalar.value)
            commands.append(.key(key,true)); commands.append(.key(key,false))
        }
        guard worker?.enqueueBatch(commands)==true else { throw DeckError("INPUT_BACKPRESSURE: input was not queued; inspect before retrying") }
    }
    func quality() {
        let q: Int
        switch profile.quality { case "text": q = -1; case "economy": q=3; case "balanced": q=7; default: q=adaptiveQuality }
        worker?.enqueue(.quality(q,profile.quality=="economy" ? 6:1))
    }
    func requestResolution(width: Int,height: Int) throws {
        guard active,let worker else {throw DeckError("Connect before changing remote resolution")}
        guard (320...8192).contains(width),(200...8192).contains(height),width*height<=33554432 else {throw DeckError("Supported request range: 320–8192 × 200–8192, up to 32 megapixels")}
        if frame?.width==width && frame?.height==height {resolutionStatus="\(width) × \(height) · current";return}
        resizeRequest += 1;let request=resizeRequest,revision=connectionRevision
        pendingResolution=(width,height);resolutionStatus="Requesting \(width) × \(height)…"
        worker.enqueue(.resize(width,height))
        Task { [weak self] in
            try? await Task.sleep(nanoseconds:6_000_000_000)
            guard let self,resizeRequest==request,pendingResolution != nil else {return}
            pendingResolution=nil
            resolutionStatus=connectionRevision==revision ? "Server did not apply the requested size" : "Resolution request interrupted by reconnect"
            if connectionRevision==revision {self.worker?.enqueue(.cancelResize)}
        }
    }
    func cancelResolution() {
        if pendingResolution != nil {resolutionStatus="Resolution request interrupted"}
        pendingResolution=nil;resizeRequest += 1
    }
    func screenshot(_ crop: CGRect?) throws -> Data {
        guard let frame, let provider=CGDataProvider(data:frame.pixels as CFData),
              let image=CGImage(width:frame.width,height:frame.height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:frame.width*4,
                 space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.noneSkipFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)
        else { throw DeckError("No framebuffer available") }
        let selected: CGImage
        if let crop {
            guard crop.width>0,crop.height>0,CGRect(x:0,y:0,width:frame.width,height:frame.height).contains(crop),let part=image.cropping(to:crop) else { throw DeckError("Crop outside framebuffer") }; selected=part
        } else { selected=image }
        guard let data=NSBitmapImageRep(cgImage:selected).representation(using:.png,properties:[:]) else { throw DeckError("PNG encoding failed") }
        return data
    }
}

@MainActor final class WorkspaceModel: ObservableObject {
    @Published var sessions=[DesktopSession]()
    @Published var saved=SavedState()
    @Published var error=""
    @Published var search=""
    @Published var profileDraft: ProfileDraft?
    @Published var keyboardFocusRequest: KeyboardFocusRequest?
    @Published var isFullScreen=false
    func toggleFullScreen() {(NSApp.keyWindow ?? NSApp.mainWindow)?.toggleFullScreen(nil)}
    var connectingPermits=0
    var networkAvailable=true
    var server: ControlServer?
    private var started=false
    private let network=NWPathMonitor()
    private var leaseTimer: Timer?
    private lazy var hostMonitor=HostMonitor {[weak self] endpoint,metrics,error in
        guard let self else {return}
        for s in sessions where s.profile.usesSSH && HostEndpoint(s.profile)==endpoint {
            if s.hostMetrics != metrics {s.hostMetrics=metrics}
            if s.hostMetricsError != error {s.hostMetricsError=error}
        }
    }
    private var observations=[UUID:AnyCancellable]()
    func observe(_ session: DesktopSession) {
        observations[session.id]=Publishers.Merge(session.$phase.removeDuplicates().map{_ in ()},session.$profile.removeDuplicates().map{_ in ()})
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }
    func assignColor(_ session: DesktopSession) {
        guard session.profile.autoTintHex==nil else {return}
        let used=Set(sessions.filter{$0.id != session.id}.compactMap{$0.profile.tintHex ?? $0.profile.autoTintHex})
        session.profile.autoTintHex=DeckTheme.palette.first{!used.contains($0.hex)}?.hex ?? DeckTheme.palette[sessions.count%DeckTheme.palette.count].hex
    }
    init() {
        do { saved=try Storage.load(); sessions=saved.profiles.map(DesktopSession.init) } catch { self.error="Cannot read saved workspace: \(error.localizedDescription)" }
        sessions.forEach{Secrets.bindLegacy($0.profile);assignColor($0);observe($0)}
        if saved.workspaces.isEmpty { saved.workspaces=[WorkspacePreset(name:"All desktops",profiles:[])] }
        if !saved.workspaces.contains(where:{$0.id==saved.selectedWorkspace}) { saved.selectedWorkspace=saved.workspaces[0].id }
    }
    var workspaceIndex: Int { saved.workspaces.firstIndex(where:{$0.id==saved.selectedWorkspace}) ?? 0 }
    var workspace: WorkspacePreset { saved.workspaces[workspaceIndex] }
    var visible: [DesktopSession] {
        workspace.profiles.compactMap { id in sessions.first{$0.id==id} }
    }
    var focused: DesktopSession? { sessions.first{$0.id==workspace.focused} ?? visible.first }
    var viewMode: ViewMode {
        guard workspace.focusMode,let s=focused else {return .overview}
        let mode=ViewMode(rawValue:s.surfaceMode) ?? .desktop
        return s.profile.supports(mode) ? mode:(s.profile.hasVNC ? .desktop:.terminal)
    }
    func setViewMode(_ mode: ViewMode,focusKeyboard: Bool=false) {
        if mode == .overview {keyboardFocusRequest=nil;updateWorkspace{$0.focusMode=false};return}
        guard let s=focused,s.profile.supports(mode) else {return}
        if mode.showsTerminal && s.terminals.isEmpty {_=openTerminal(s,present:false)}
        s.releaseInput();s.surfaceMode=mode.rawValue
        updateWorkspace{$0.focusMode=true;$0.focused=s.id}
        if focusKeyboard {requestKeyboardFocus()}
    }
    func requestKeyboardFocus(terminal: Bool=false) {
        guard let s=focused,viewMode != .overview else {keyboardFocusRequest=nil;return}
        let terminalID: UUID?
        if terminal || !viewMode.showsDesktop {
            guard viewMode.showsTerminal,let tab=s.selectedTab else {keyboardFocusRequest=nil;return}
            terminalID=tab.id;tab.lease.human()
        } else {terminalID=nil;s.humanInput()}
        let id=UUID(),profile=s.id
        keyboardFocusRequest=KeyboardFocusRequest(id:id,profile:profile,terminal:terminalID,window:NSApp.keyWindow) {[weak self] in
            guard let self,self.keyboardFocusRequest?.id==id,self.focused?.id==profile else {return false}
            return terminalID.map{self.viewMode.showsTerminal && self.focused?.selectedTerminal==$0} ?? self.viewMode.showsDesktop
        }
    }
    func keyboardFocus(for profile: UUID,terminal: UUID?=nil) -> KeyboardFocusRequest? {
        guard let request=keyboardFocusRequest,request.profile==profile,request.terminal==terminal else {return nil}
        return request
    }
    func updateWorkspace(_ edit: (inout WorkspacePreset)->Void) {edit(&saved.workspaces[workspaceIndex]);saved.workspaces[workspaceIndex].normalize();updateRenderingRates();persist()}
    func updateRenderingRates() {
        for s in sessions { s.worker?.setFPS(workspace.focusMode && focused?.id==s.id ? (s.surfaceMode=="terminal" ? 2:30):12) }
    }
    func persist() {
        saved.profiles=sessions.map {s in var profile=s.profile;profile.surfaceMode=s.surfaceMode;return profile}
        saved.terminals=sessions.flatMap { s in s.terminals.map{SavedTerminal(id:$0.id,profile:s.id,reconnect:$0.desired,profileSnapshot:$0.profile)} }
        do { try Storage.save(saved) } catch { self.error=error.localizedDescription }
    }
    func start() {
        guard !started else { return }; started=true
        let terminalRecords=saved.terminals ?? []
        let arguments=ProcessInfo.processInfo.arguments
        if let index=arguments.firstIndex(of:"--import-profiles"),arguments.count>index+1 {
            do {
                let profiles=try JSONDecoder().decode([Profile].self,from:Data(contentsOf:URL(fileURLWithPath:arguments[index+1])))
                for p in profiles where !sessions.contains(where:{$0.id==p.id}) { try add(p,password:nil) }
            } catch { self.error=error.localizedDescription }
        }
        do { server=try ControlServer(model:self) } catch { self.error=error.localizedDescription }
        for record in terminalRecords {
            if let s=sessions.first(where:{$0.id==record.profile}) {
                let tab=makeTerminal(s,id:record.id,profile:record.profileSnapshot);s.terminals.append(tab)
                if tab.profile.hasSameTerminalConnection(as:s.profile) {s.selectedTerminal=tab.id}
                if record.reconnect { tab.connect() }
            }
        }
        persist()
        network.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.networkAvailable=path.status == .satisfied }
        }
        network.start(queue:DispatchQueue(label:"dev.desktop-deck.network"))
        leaseTimer=Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self] _ in
            Task { @MainActor in guard let self else { return }
                let now=ProcessInfo.processInfo.systemUptime
                for s in self.sessions {
                    let countdown=max(0,Int(ceil(s.retryAt?.timeIntervalSinceNow ?? 0)))
                    if s.retryCountdown != countdown {s.retryCountdown=countdown}
                    s.sampleActivity(at:now)
                    if s.imageUploading {s.lease.human()}
                }
                for s in self.sessions where s.lease.owner != nil && Date() >= s.lease.expiry { s.releaseInput(); s.lease=InputLease() }
                self.hostMonitor.tick(self.sessions,enabled:UserDefaults.standard.object(forKey:"showHostMetrics") as? Bool ?? true)
            }
        }
        for session in sessions where session.profile.autoConnect && !session.wantsConnection { connect(session) }
    }
    func add(_ profile: Profile,password: String?) throws {
        try profile.validate()
        if let password { try Secrets.set(password,profile:profile) }
        let existing=sessions.first{$0.id==profile.id}
        let enableAutoConnect=profile.autoConnect && existing?.profile.autoConnect != true
        if let session=existing {
            let previous=session.profile
            let vncChanged = !profile.hasSameVNCConnection(as:previous) || (profile.hasVNC && password != nil)
            if vncChanged {
                // Disconnect only the VNC transport here; terminal ownership is independent.
                if previous.hasVNC {disconnect(session)}
                session.frame=nil;session.geometry += 1;session.previousDisplay=nil;session.remoteSessions=[]
            }
            if !profile.hasSameTerminalConnection(as:previous) {session.selectedTerminal=session.terminals.last{$0.profile.hasSameTerminalConnection(as:profile)}?.id}
            session.profile=profile
            if !profile.hasSameSSHConnection(as:previous) {session.hostMetrics=nil;session.hostMetricsError=""}
            if profile.quality != previous.quality {session.quality()}
        }
        else { let s=DesktopSession(profile); sessions.append(s);assignColor(s);observe(s); saved.workspaces[workspaceIndex].profiles.append(profile.id) }
        persist()
        if enableAutoConnect,let session=sessions.first(where:{$0.id==profile.id}),!session.isOnline,!session.wantsConnection {connect(session)}
    }
    func delete(_ session: DesktopSession) {
        disconnect(session); session.terminals.forEach{$0.detach()}
        sessions.removeAll{$0.id==session.id}; observations.removeValue(forKey:session.id); for i in saved.workspaces.indices { saved.workspaces[i].profiles.removeAll{$0==session.id} }
        try? Secrets.set("",profile:session.profile); persist()
    }
    func refreshSessions(_ s: DesktopSession) async { do { s.remoteSessions=try await Commands.list(s.profile) } catch { s.detail=error.localizedDescription } }
    func selectSession(_ s: DesktopSession,display: String) {
        guard display != s.profile.display else {return}
        let previous=s.profile.display;disconnect(s);s.profile.display=display;s.previousDisplay=previous
        s.frame=nil;s.geometry += 1;persist();connect(s)
    }
    func createSession(_ s: DesktopSession) async throws {
        let output=try await Commands.ssh(s.profile,"\(Commands.serverTool(s.profile,"vncserver")) -sessionstart -securitytypes otp",timeout:30)
        guard let created=try RemoteSession.parse(output).first else { throw DeckError("No new session returned") }
        selectSession(s,display:created.display);await refreshSessions(s)
    }
    func openTerminal(_ s: DesktopSession,present: Bool=true,focusKeyboard: Bool=true) -> TerminalTab {
        let tab=makeTerminal(s);s.terminals.append(tab);s.selectedTerminal=tab.id;tab.connect()
        if present {
            s.surfaceMode=s.surfaceMode=="split" ? "split":"terminal"
            updateWorkspace {if !$0.profiles.contains(s.id) {$0.profiles.append(s.id)};$0.focused=s.id;$0.focusMode=true}
            if focusKeyboard {requestKeyboardFocus(terminal:true)}
        }
        updateRenderingRates();persist();return tab
    }
    private func makeTerminal(_ s: DesktopSession,id: UUID=UUID(),profile: Profile?=nil) -> TerminalTab {
        let tab=TerminalTab(profile:profile ?? s.profile,id:id)
        tab.view.feedback = {[weak s] message in s?.showFeedback(message)}
        s.terminalObservations[tab.id]=tab.$connection.removeDuplicates().sink {[weak self,weak s] _ in s?.objectWillChange.send();self?.objectWillChange.send()}
        return tab
    }
    func editProfile(_ s: DesktopSession?=nil) {profileDraft=ProfileDraft(profile:s?.profile ?? Profile())}
    func duplicateProfile(_ s: DesktopSession) {
        profileDraft=ProfileDraft(profile:s.profile.duplicated(),duplicateSource:s.id)
    }
    var sidebarSessions: [DesktopSession] {
        let order=workspace.profiles+sessions.map(\.id).filter{!workspace.profiles.contains($0)}
        return order.compactMap{id in sessions.first{$0.id==id}}.filter{search.isEmpty || $0.profile.name.localizedCaseInsensitiveContains(search) || $0.profile.group.localizedCaseInsensitiveContains(search)}
    }
    func moveSidebar(from offsets: IndexSet,to destination: Int) {
        var order=sidebarSessions.map(\.id);order.move(fromOffsets:offsets,toOffset:destination)
        let ids=ConnectionOrder.reorder(sessions.map(\.id),using:order)
        let byID=Dictionary(uniqueKeysWithValues:sessions.map{($0.id,$0)})
        sessions=ids.compactMap{byID[$0]}
        updateWorkspace{$0.profiles=ConnectionOrder.reorder($0.profiles,using:order)}
    }
    func moveInWorkspace(_ source: UUID,relativeTo target: UUID,after: Bool) -> Bool {
        guard source != target,workspace.profiles.contains(source),workspace.profiles.contains(target) else {return false}
        updateWorkspace{p in p.profiles.removeAll{$0==source};if let index=p.profiles.firstIndex(of:target){p.profiles.insert(source,at:index+(after ? 1:0))}}
        return true
    }
    func moveInWorkspace(_ source: UUID,by offset: Int) {
        guard let index=workspace.profiles.firstIndex(of:source),workspace.profiles.indices.contains(index+offset) else {return}
        _=moveInWorkspace(source,relativeTo:workspace.profiles[index+offset],after:offset>0)
    }
    func stop() {persist();leaseTimer?.invalidate();hostMonitor.stop();network.cancel();sessions.forEach{disconnect($0);$0.terminals.forEach{$0.detach()}};server?.stop()}
}
