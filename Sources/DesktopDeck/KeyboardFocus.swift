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
        guard isCurrent(),let originWindow else {completed=true;return}
        guard let window=view.window else {return}
        guard window===originWindow,window.isKeyWindow,window.attachedSheet==nil else {completed=true;return}
        guard !view.isHiddenOrHasHiddenAncestor,!view.bounds.isEmpty else {return}
        let current=window.firstResponder
        guard current===originResponder || current===window || current==nil || view.ownsKeyboardFocus else {completed=true;return}
        completed=true
        window.makeFirstResponder(view)
    }
}
