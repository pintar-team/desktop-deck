import AppKit

@MainActor extension NSView {
    var ownsKeyboardFocus: Bool {
        guard let first=window?.firstResponder as? NSView else {return false}
        return first===self || first.isDescendant(of:self)
    }
}

@MainActor final class KeyboardFocusRequest {
    let id: UUID
    let profile: UUID
    let terminal: UUID?
    private weak var originWindow: NSWindow?
    private weak var originResponder: NSResponder?
    private weak var pendingView: NSView?
    private let isCurrent: ()->Bool
    private var completed=false
    private var scheduled=false
    private(set) var status="pending"
    init(id: UUID,profile: UUID,terminal: UUID?,window: NSWindow?,isCurrent: @escaping ()->Bool) {
        self.id=id;self.profile=profile;self.terminal=terminal
        originWindow=window;originResponder=window?.firstResponder;self.isCurrent=isCurrent
    }
    func schedule(on view: NSView) {
        guard !completed else {return}
        pendingView=view
        guard !scheduled else {return}
        scheduled=true
        DispatchQueue.main.async {[weak self] in
            guard let self else {return};self.scheduled=false
            if let view=self.pendingView {self.apply(to:view)}
        }
    }
    func apply(to view: NSView) {
        guard !completed else {return}
        guard isCurrent() else {cancel("superseded");return}
        guard let originWindow else {cancel("no-source-window");return}
        guard let window=view.window else {status="awaiting-view";return}
        guard window===originWindow else {cancel("window-changed");return}
        guard window.isKeyWindow else {cancel("window-inactive");return}
        guard window.attachedSheet==nil else {cancel("sheet-open");return}
        guard !view.isHiddenOrHasHiddenAncestor,!view.bounds.isEmpty else {status="awaiting-layout";return}
        let current=window.firstResponder
        if (current is NSTextView || current is NSTextField),current !== originResponder,!view.ownsKeyboardFocus {cancel("editing-changed");return}
        completed=true
        status=window.makeFirstResponder(view) ? "focused":"declined"
    }
    private func cancel(_ reason: String) {completed=true;status=reason}
}
