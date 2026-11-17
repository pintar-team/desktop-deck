import AppKit
import SwiftUI
import SwiftTerm
import DeckCore

@MainActor final class DeckTerminalView: LocalProcessTerminalView {
    var human: (()->Void)?
    var feedback: ((String)->Void)?
    override func mouseDown(with event: NSEvent) { human?(); super.mouseDown(with:event) }
    override func paste(_ sender: Any) {
        human?();super.paste(sender)
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
    @Published var status="Disconnected"
    @Published var persistent=false
    @Published var generation=0
    var outputRevision=0
    let view=DeckTerminalView(frame:NSRect(x:0,y:0,width:800,height:260))
    var lease=InputLease()
    var desired=false
    private var reconnect: Task<Void,Never>?
    private var retry=0
    private var eventMonitor: Any?
    var tmuxName: String { "deck-"+id.uuidString.lowercased() }
    init(profile: Profile,id: UUID=UUID()) {
        self.profile=profile; self.id=id
        view.processDelegate=self; view.font=NSFont.monospacedSystemFont(ofSize:13,weight:.regular)
        view.human = { [weak self] in self?.lease.human() }
        view.setProcessOutputHandler { [weak self] in Task { @MainActor in self?.outputRevision += 1 } }
        eventMonitor=NSEvent.addLocalMonitorForEvents(matching:[.keyDown,.leftMouseDown,.rightMouseDown]) { [weak self] event in
            if let self,event.window===view.window,let first=event.window?.firstResponder as? NSView,
               first===view || first.isDescendant(of:view) { lease.human() }
            return event
        }
    }
    func connect() {
        guard profile.usesSSH else { status="SSH is not configured for this profile"; return }
        desired=true; reconnect?.cancel(); generation += 1
        let g=generation; status="Connecting"
        reconnect=Task { [weak self] in
            guard let self else { return }
            do {
                if profile.terminalMode != "plain" {
                    let r=try await Commands.ssh(profile,"command -v tmux >/dev/null 2>&1 && printf DECK_TMUX || true")
                    persistent=r.contains("DECK_TMUX")
                }
                guard desired,generation==g else { return }
                let command=persistent ? "exec tmux -L desktop-deck new-session -A -s \(Shell.quote(tmuxName))" : "exec \"${SHELL:-/bin/sh}\" -l"
                view.startProcess(executable:"/usr/bin/ssh",args:Shell.sshArguments(profile,interactive:true)+["--",profile.sshHost,command],environment:["TERM=xterm-256color","LANG=en_US.UTF-8","PATH=/usr/bin:/bin:/usr/sbin:/sbin"])
                status=persistent ? "Connected · persistent" : "Connected · plain SSH"
            } catch {desired=false;status=error.localizedDescription}
        }
    }
    func detach() { desired=false; generation += 1; reconnect?.cancel(); view.terminate(); status="Detached"; lease=InputLease() }
    func end() async throws {
        detach()
        if persistent { _=try await Commands.ssh(profile,"tmux -L desktop-deck kill-session -t \(Shell.quote(tmuxName))") }
        status="Ended"
    }
    func send(_ text: String) { view.send(source:view,data:Array(text.utf8)[...]) }
    func read(limit: Int) -> String {
        guard let snapshot=view.terminalContentSnapshot(region:.history(maximumScrollbackRows:1000)) else { return "" }
        return String(snapshot.rows.map(\.text).joined(separator:"\n").suffix(min(max(limit,1),65536)))
    }
    func sizeChanged(source: LocalProcessTerminalView,newCols: Int,newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView,title: String) { self.title=String(title.prefix(80)) }
    func hostCurrentDirectoryUpdate(source: TerminalView,directory: String?) {}
    func processTerminated(source: TerminalView,exitCode: Int32?) {
        lease=InputLease(); generation += 1
        guard desired else { return }
        if !persistent {desired=false}
        status=persistent ? "Reconnecting" : "Disconnected · reconnect opens a new shell"
        if persistent {
            let delay=RetryPolicy.delay(attempt:retry,jitter:1); retry += 1
            reconnect=Task { [weak self] in try? await Task.sleep(nanoseconds:UInt64(delay*1e9)); guard let self,!Task.isCancelled,desired else { return }; connect() }
        }
    }
    func processFailedToStart(source: TerminalView,error: LocalProcessError) {desired=false;status="SSH process could not start"}
    deinit { if let eventMonitor { NSEvent.removeMonitor(eventMonitor) } }
}
@MainActor final class TerminalContainer: NSView {
    let terminal: DeckTerminalView
    init(_ terminal: DeckTerminalView) {
        self.terminal=terminal;super.init(frame:.zero)
        wantsLayer=true;layer?.masksToBounds=true
        addSubview(terminal)
    }
    required init?(coder: NSCoder) {fatalError("init(coder:) unavailable")}
    private func fitTerminal() {
        terminal.setFrameOrigin(.zero)
        // SwiftTerm resizes its terminal model and PTY in setFrameSize.
        // Assigning the frame rectangle can bypass that AppKit override.
        if bounds.width>0 && bounds.height>0 {terminal.setFrameSize(bounds.size)}
    }
    override func setFrameSize(_ size: NSSize) {super.setFrameSize(size);fitTerminal()}
    override func layout() {super.layout();fitTerminal()}
}
struct TerminalSurface: NSViewRepresentable {
    let tab: TerminalTab
    func makeNSView(context: Context) -> TerminalContainer {TerminalContainer(tab.view)}
    func updateNSView(_ nsView: TerminalContainer,context: Context) {nsView.needsLayout=true}
    func sizeThatFits(_ proposal: ProposedViewSize,nsView: TerminalContainer,context: Context) -> CGSize? {
        CGSize(width:proposal.width ?? 800,height:proposal.height ?? 400)
    }
}
