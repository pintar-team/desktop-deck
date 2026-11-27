import SwiftUI
import AppKit

enum DeckTheme {
    static let background=Color(red:0.025,green:0.04,blue:0.065)
    static let panel=Color(red:0.055,green:0.075,blue:0.105)
    static let accent=Color(red:0.22,green:0.84,blue:0.77)
    static let border=Color(red:0.23,green:0.3,blue:0.37)
    static let palette: [(name:String,hex:String)] = [
        ("Lagoon","38D6C4"),("Coral","FF8A7A"),("Iris","B5A0FF"),("Honey","F5CB70"),
        ("Sky","7AC8FF"),("Rose","F59FCB"),("Lime","BEDD77"),("Periwinkle","98ADFF"),
        ("Apricot","FFB885"),("Glacier","83E4E8"),("Orchid","D49BF3"),("Jade","7FD5A1")]
    static func color(_ hex: String) -> Color {
        guard let rgb=UInt32(hex.replacingOccurrences(of:"#",with:""),radix:16) else {return accent}
        return Color(red:Double((rgb>>16)&255)/255,green:Double((rgb>>8)&255)/255,blue:Double(rgb&255)/255)
    }
    static func hex(_ color: Color) -> String {
        guard let rgb=NSColor(color).usingColorSpace(.sRGB) else {return "38D6C4"}
        return String(format:"%02X%02X%02X",Int(rgb.redComponent*255),Int(rgb.greenComponent*255),Int(rgb.blueComponent*255))
    }
}

@MainActor enum WindowLayout {
    static func insets(_ window: NSWindow) -> (titlebar: CGFloat,screen: CGFloat) {
        guard let content=window.contentView,!content.bounds.isEmpty,!window.contentLayoutRect.isEmpty else {return (0,0)}
        let layout=content.convert(window.contentLayoutRect,from:nil)
        let titlebar=content.isFlipped ? layout.minY-content.bounds.minY:content.bounds.maxY-layout.maxY
        let contentTop=window.convertToScreen(content.convert(content.bounds,to:nil)).maxY
        let screenTop=window.screen.map{$0.frame.maxY-$0.safeAreaInsets.top} ?? contentTop
        return (max(0,titlebar),max(0,contentTop-screenTop))
    }
    static func topInset(_ window: NSWindow) -> CGFloat {
        guard window.styleMask.contains(.fullScreen) else {return 0}
        // Full-screen native chrome auto-hides; only the physical screen cutout
        // needs space here. contentLayoutRect still reserves the hidden title bar.
        return insets(window).screen
    }
    static func info(_ window: NSWindow?) -> [String:Any] {
        guard let window else {return ["available":false]}
        let insets=insets(window)
        return ["available":true,"fullScreen":window.styleMask.contains(.fullScreen),"topInset":topInset(window),"titlebarInset":insets.titlebar,"screenInset":insets.screen,"nativeSafeTop":window.contentView?.safeAreaInsets.top ?? 0]
    }
}

struct WindowBackdrop: NSViewRepresentable {
    let updateLayout: (Bool,CGFloat)->Void
    func makeCoordinator() -> CloseConfirmation { CloseConfirmation() }
    func makeNSView(context: Context) -> NSView {NSView()}
    func updateNSView(_ view: NSView,context: Context) {
        DispatchQueue.main.async { [weak coordinator=context.coordinator] in
            guard let window=view.window else {return}
            coordinator?.attach(to:window)
            if window.titleVisibility != .hidden {window.titleVisibility = .hidden}
            if !window.titlebarAppearsTransparent {window.titlebarAppearsTransparent=true}
            if window.toolbar != nil {window.toolbar=nil}
            if window.titlebarSeparatorStyle != .none {window.titlebarSeparatorStyle = .none}
            window.acceptsMouseMovedEvents=true
            if !window.styleMask.contains(.fullSizeContentView) {window.styleMask.insert(.fullSizeContentView)}
            window.backgroundColor=NSColor(red:0.025,green:0.04,blue:0.065,alpha:1)
            for button in [NSWindow.ButtonType.closeButton,.miniaturizeButton,.zoomButton] {window.standardWindowButton(button)?.isHidden=true}
            updateLayout(window.styleMask.contains(.fullScreen),WindowLayout.topInset(window))
        }
    }
    static func dismantleNSView(_ view: NSView,coordinator: CloseConfirmation) { coordinator.detach() }

    static func requestClose(_ window: NSWindow?) {
        guard let window else { return }
        if let confirmation=window.delegate as? CloseConfirmation { _=confirmation.windowShouldClose(window) }
        else { window.performClose(nil) }
    }

    @MainActor final class CloseConfirmation: NSObject, NSWindowDelegate {
        private weak var window: NSWindow?
        private weak var original: (any NSWindowDelegate)?

        func attach(to window: NSWindow) {
            guard window.delegate !== self else { return }
            detach()
            self.window=window
            original=window.delegate
            window.delegate=self
        }

        func detach() {
            if let window, window.delegate === self { window.delegate=original }
            window=nil
            original=nil
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to:selector) || original?.responds(to:selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            if original?.responds(to:selector) == true { return original }
            return super.forwardingTarget(for:selector)
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard sender.attachedSheet == nil else { return false }
            let alert=NSAlert()
            alert.messageText="Close Desktop Deck window?"
            alert.informativeText="Desktop Deck stays running and keeps its connections open."
            alert.addButton(withTitle:"Cancel").keyEquivalent="\r"
            alert.addButton(withTitle:"Close Window").hasDestructiveAction=true
            alert.beginSheetModal(for:sender) { [weak self,weak sender] response in
                guard response == .alertSecondButtonReturn,let self,let sender,
                      self.original?.windowShouldClose?(sender) != false else { return }
                sender.close()
            }
            return false
        }
    }
}
