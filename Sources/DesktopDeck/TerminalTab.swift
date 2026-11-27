import AppKit
import SwiftUI
import SwiftTerm
import DeckCore

final class TerminalTiming: @unchecked Sendable {
    private let lock=NSLock()
    private var inputAt: TimeInterval?
    private var outputBatches=0
    var revision: Int {lock.lock();defer{lock.unlock()};return outputBatches}
    private var eventDelay: Double?,echoDelay: Double?
    func input(eventTime: TimeInterval?=nil) {
        let now=ProcessInfo.processInfo.systemUptime
        lock.lock();defer{lock.unlock()}
        inputAt=now
        if let eventTime {eventDelay=max(0,(now-eventTime)*1000)}
    }
    func output() {
        let now=ProcessInfo.processInfo.systemUptime
        lock.lock();defer{lock.unlock()}
        if let inputAt,now-inputAt<2 {echoDelay=(now-inputAt)*1000}
        outputBatches += 1
        inputAt=nil
    }
    func reset() {lock.lock();inputAt=nil;eventDelay=nil;echoDelay=nil;lock.unlock()}
    var snapshot: [String:Double] {
        lock.lock();defer{lock.unlock()}
        return ["eventDispatchMs":eventDelay,"inputToNextOutputMs":echoDelay].compactMapValues{$0}
    }
}

@MainActor final class DeckTerminalView: LocalProcessTerminalView {
    var human: (()->Void)?
    var feedback: ((String)->Void)?
    let timing=TerminalTiming()
    override func mouseDown(with event: NSEvent) { human?(); super.mouseDown(with:event) }
    override func paste(_ sender: Any) {
        human?();timing.input();super.paste(sender)
        if NSPasteboard.general.string(forType:.string) != nil {feedback?("Pasted")}
    }
    override func copy(_ sender: Any) {
        human?();let change=NSPasteboard.general.changeCount;super.copy(sender)
        if NSPasteboard.general.changeCount != change {feedback?("Copied")}
    }
}
@MainActor final class TerminalTab: ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    let id: UUID
    let profile: Profile
    @Published var title="Terminal"
    struct Connection: Equatable {
        let indicator: ConnectionIndicator, message: String
    }
    @Published private(set) var connection=Connection(indicator:.offline,message:"Disconnected")
    var status: String {connection.message}
    var isOnline: Bool {connection.indicator == .online}
    private func report(_ indicator: ConnectionIndicator,_ message: String) {connection=Connection(indicator:indicator,message:message)}
    private func reportFailure(_ message: String) {desired=false;report(.attention,message)}
    @Published var persistent=false
    @Published private(set) var isEnding=false
    private(set) var tmuxSessionPossible: Bool?
    var mayHaveTmuxSession: Bool {profile.terminalMode != "plain" && tmuxSessionPossible != false}
    @Published var generation=0
    var outputRevision: Int {view.timing.revision}
    let view=DeckTerminalView(frame:NSRect(x:0,y:0,width:800,height:260))
    var lease=InputLease()
    var desired=false
    private var reconnect: Task<Void,Never>?
    private var processActive=false
    private var stopping=false
    private var retry=0
    private var startedAt: ContinuousClock.Instant?
    private var eventMonitor: Any?
    var tmuxName: String { "deck-"+id.uuidString.lowercased() }
    init(profile: Profile,id: UUID=UUID(),tmuxSessionPossible: Bool?=nil) {
        self.profile=profile; self.id=id; self.tmuxSessionPossible=tmuxSessionPossible
        view.processDelegate=self; view.font=NSFont.monospacedSystemFont(ofSize:13,weight:.regular)
        view.human = { [weak self] in self?.lease.human() }
        let timing=view.timing
        view.setProcessOutputHandler { timing.output() }
        eventMonitor=NSEvent.addLocalMonitorForEvents(matching:[.keyDown,.leftMouseDown,.rightMouseDown]) { [weak self] event in
            if let self,event.window===view.window,let first=event.window?.firstResponder as? NSView,
               first===view || first.isDescendant(of:view) {
                lease.human()
                if event.type == .keyDown {view.timing.input(eventTime:event.timestamp)}
            }
            return event
        }
    }
    func connect() {
        guard !isEnding else {return}
        retry = 0
        startConnectionAttempt()
    }
    private func startConnectionAttempt() {
        guard profile.usesSSH else { reportFailure("SSH is not configured for this profile"); return }
        desired=true; reconnect?.cancel(); generation += 1
        let g=generation; report(.connecting,"Connecting")
        if processActive {
            stopping=true;view.terminate()
            reconnect=Task { [weak self] in
                try? await Task.sleep(nanoseconds:5_000_000_000)
                guard let self,!Task.isCancelled,desired,processActive else {return}
                reportFailure("SSH is still closing · retry")
            }
            return
        }
        reconnect=Task { [weak self] in
            guard let self else { return }
            do {
                var useTmux=false
                if profile.terminalMode != "plain" {
                    let r=try await Commands.ssh(profile,"command -v tmux >/dev/null 2>&1 && printf DECK_TMUX || true")
                    useTmux=r.contains("DECK_TMUX")
                }
                guard !Task.isCancelled,desired,generation==g else { return }
                tmuxSessionPossible = tmuxSessionPossible == true || useTmux
                persistent=useTmux;processActive=true;startedAt=ContinuousClock.now;view.timing.reset()
                let command=persistent ? "exec tmux -L desktop-deck new-session -A -s \(Shell.quote(tmuxName))" : "exec \"${SHELL:-/bin/sh}\" -l"
                view.startProcess(
                    executable: "/usr/bin/ssh",
                    args: Shell.sshArguments(profile, interactive: true) + ["--", profile.sshHost, command],
                    environment: Shell.sshTerminalEnvironment()
                )
                report(.online,persistent ? "Connected · persistent" : "Connected · plain SSH")
            } catch {
                guard !Task.isCancelled,generation==g else {return}
                let message = error.localizedDescription
                if Shell.isTransientSSHFailure(message) { scheduleReconnect(after: message) }
                else { reportFailure(message) }
            }
        }
    }
    private func scheduleReconnect(after message: String) {
        guard retry + 1 < ConnectionLimits.attempts else {
            reportFailure("Reconnect attempts exhausted · \(message)")
            return
        }
        let delay = RetryPolicy.delay(attempt: retry, jitter: 1)
        retry += 1
        report(.connecting, "Reconnecting · \(retry + 1)/\(ConnectionLimits.attempts) · \(message)")
        let revision = generation
        reconnect = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, desired, generation == revision else { return }
            startConnectionAttempt()
        }
    }
    func detach() {
        guard !isEnding else {return}
        desired=false; generation += 1; reconnect?.cancel(); stopping=processActive; view.terminate(); report(.offline,"Detached"); lease=InputLease()
    }
    func end() async throws {
        guard !isEnding else {throw DeckError("Terminal is already closing")}
        detach()
        isEnding=true
        report(.connecting,"Ending terminal…")
        defer {isEnding=false}
        do {
            // Wait for the attaching SSH client before touching its tmux session.
            let deadline=ContinuousClock.now.advanced(by:.seconds(5))
            while processActive {
                guard ContinuousClock.now < deadline else {throw DeckError("SSH is still closing · retry")}
                try await Task.sleep(for:.milliseconds(50))
            }
            if mayHaveTmuxSession {
                let target=Shell.quote("="+tmuxName)
                // Only absence of this exact target or its socket is success.
                _=try await Commands.ssh(profile,"""
                    message=$(LC_ALL=C tmux -L desktop-deck kill-session -t \(target) 2>&1) || {
                        case "$message" in
                            "can't find session: \(tmuxName)"|"can't find session: =\(tmuxName)"|"no server running on "*|"error connecting to "*" (No such file or directory)") exit 0 ;;
                        esac
                        printf '%s\\n' "$message" >&2
                        exit 1
                    }
                    """)
                tmuxSessionPossible=false
            }
            report(.offline,"Ended")
        } catch {
            reportFailure(error.localizedDescription)
            throw error
        }
    }
    func send(_ text: String) { view.timing.input();view.send(source:view,data:Array(text.utf8)[...]) }
    func read(limit: Int) -> String {
        guard let snapshot=view.terminalContentSnapshot(region:.history(maximumScrollbackRows:1000)) else { return "" }
        return String(snapshot.rows.map(\.text).joined(separator:"\n").suffix(min(max(limit,1),65536)))
    }
    func sizeChanged(source: LocalProcessTerminalView,newCols: Int,newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView,title: String) { self.title=String(title.prefix(80)) }
    func hostCurrentDirectoryUpdate(source: TerminalView,directory: String?) {}
    func processTerminated(source: TerminalView,exitCode: Int32?) {
        processActive=false
        let uptime = startedAt.map { $0.duration(to: .now) }
        startedAt = nil
        if stopping {
            stopping=false;reconnect?.cancel()
            if desired {startConnectionAttempt()}
            return
        }
        lease=InputLease(); generation += 1
        guard desired else { return }
        if persistent {
            if let uptime, uptime >= .seconds(ConnectionLimits.stableSeconds) { retry = 0 }
            scheduleReconnect(after: "SSH connection ended")
        } else {
            desired=false
            report(exitCode==0 ? .offline:.attention, "Disconnected · reconnect opens a new shell")
        }
    }
    func processFailedToStart(source: TerminalView,error: LocalProcessError) {processActive=false;stopping=false;startedAt=nil;reportFailure("SSH process could not start")}
    deinit { if let eventMonitor { NSEvent.removeMonitor(eventMonitor) } }
}
@MainActor final class TerminalContainer: NSView {
    private(set) var terminal: DeckTerminalView?
    var focusRequest: KeyboardFocusRequest?
    init(_ terminal: DeckTerminalView) {
        super.init(frame:.zero)
        wantsLayer=true;layer?.masksToBounds=true
        bind(terminal)
    }
    required init?(coder: NSCoder) {fatalError("init(coder:) unavailable")}
    func bind(_ next: DeckTerminalView) {
        guard terminal !== next else {fitTerminal();return}
        let restoreFocus=ownsFirstResponder
        unbind();terminal=next;addSubview(next);fitTerminal()
        if restoreFocus {window?.makeFirstResponder(next)}
    }
    private var ownsFirstResponder: Bool {
        terminal?.superview===self && terminal?.ownsKeyboardFocus==true
    }
    func unbind() {
        if let terminal,terminal.superview===self {
            if ownsFirstResponder {window?.makeFirstResponder(nil)}
            terminal.removeFromSuperview()
        }
        terminal=nil;focusRequest=nil
    }
    private func fitTerminal() {
        guard let terminal,terminal.superview===self else {return}
        terminal.setFrameOrigin(.zero)
        // SwiftTerm resizes its terminal model and PTY in setFrameSize.
        // Assigning the frame rectangle can bypass that AppKit override.
        if bounds.width>0 && bounds.height>0,terminal.frame.size != bounds.size {terminal.setFrameSize(bounds.size)}
        focusRequest?.schedule(on:terminal)
    }
    override func setFrameSize(_ size: NSSize) {super.setFrameSize(size);fitTerminal()}
    override func layout() {super.layout();fitTerminal()}
    override func viewDidMoveToWindow() {super.viewDidMoveToWindow();fitTerminal()}
}
struct TerminalSurface: NSViewRepresentable {
    let tab: TerminalTab
    var focusRequest: KeyboardFocusRequest?=nil
    func makeNSView(context: Context) -> TerminalContainer {TerminalContainer(tab.view)}
    func updateNSView(_ nsView: TerminalContainer,context: Context) {nsView.bind(tab.view);nsView.focusRequest=focusRequest;focusRequest?.schedule(on:tab.view)}
    static func dismantleNSView(_ nsView: TerminalContainer,coordinator: ()) {nsView.unbind()}
    func sizeThatFits(_ proposal: ProposedViewSize,nsView: TerminalContainer,context: Context) -> CGSize? {
        CGSize(width:proposal.width ?? 800,height:proposal.height ?? 400)
    }
}
