import AppKit
import SwiftUI

struct SidebarResizeHandle: NSViewRepresentable {
    let width: Double
    let change: (Double)->Void
    let finish: (Double)->Void
    static let limits=170.0...300.0
    static func clamp(_ width: Double) -> Double {min(limits.upperBound,max(limits.lowerBound,width.isFinite ? width:205))}
    func makeNSView(context: Context) -> ResizeView {ResizeView()}
    func updateNSView(_ view: ResizeView,context: Context) {
        view.width=Self.clamp(width);view.change=change;view.finish=finish;view.setAccessibilityValue(view.width)
    }
    final class ResizeView: NSView {
        var width=205.0
        var change: (Double)->Void={_ in}
        var finish: (Double)->Void={_ in}
        private var anchor: (x:CGFloat,width:Double)?
        override var mouseDownCanMoveWindow: Bool {false}
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {true}
        override init(frame: NSRect) {
            super.init(frame:frame)
            setAccessibilityElement(true);setAccessibilityRole(.splitter);setAccessibilityLabel("Resize connections sidebar")
        }
        required init?(coder: NSCoder) {nil}
        override func resetCursorRects() {addCursorRect(bounds,cursor:.resizeLeftRight)}
        override func mouseDown(with event: NSEvent) {anchor=(event.locationInWindow.x,width)}
        override func mouseDragged(with event: NSEvent) {
            guard let anchor else {return}
            // The handle itself moves. Window coordinates keep the drag origin fixed.
            width=SidebarResizeHandle.clamp(anchor.width+Double(event.locationInWindow.x-anchor.x))
            setAccessibilityValue(width);change(width)
        }
        override func mouseUp(with event: NSEvent) {
            guard anchor != nil else {return}
            mouseDragged(with:event);anchor=nil;finish(width)
        }
        private func adjust(_ delta: Double) -> Bool {
            width=SidebarResizeHandle.clamp(width+delta);setAccessibilityValue(width);change(width);finish(width);return true
        }
        override func accessibilityPerformIncrement() -> Bool {adjust(10)}
        override func accessibilityPerformDecrement() -> Bool {adjust(-10)}
    }
}
