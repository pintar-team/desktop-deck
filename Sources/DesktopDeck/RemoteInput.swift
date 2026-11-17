import AppKit
import SwiftUI
import DeckCore
import CVNC

struct FeedbackNotice: Identifiable {
    let id=UUID()
    let text: String
}
@MainActor extension DesktopSession {
    func showFeedback(_ text: String) {
        let notice=FeedbackNotice(text:text);feedback=notice
        Task {[weak self] in
            try? await Task.sleep(nanoseconds:1_800_000_000)
            if self?.feedback?.id==notice.id {self?.feedback=nil}
        }
    }
    func resetClipboard() {cancelImageTransfer();remoteClipboard=nil;clipboardInFlight=false;clipboardPasteKeys=nil;clipboardStatus="Idle";copyFeedbackIntent=CopyFeedbackIntent()}
    func receiveClipboard(_ text: String) {
        remoteClipboard=text
        if text.isEmpty,NSPasteboard.general.availableType(from:[.png,.tiff,.fileURL]) != nil {return}
        guard UserDefaults.standard.object(forKey:"syncFocusedClipboard") as? Bool ?? true,
              let inputView,inputView.session?.id==id,let window=inputView.window,window.isKeyWindow,NSApp.isActive,
              window.firstResponder === inputView else {return}
        copyRemoteClipboard(notify:copyFeedbackIntent.consume())
    }
    func copyRemoteClipboard(notify: Bool=true) {
        guard let text=remoteClipboard else {showFeedback("Remote clipboard is empty");return}
        if NSPasteboard.general.string(forType:.string) != text {
            NSPasteboard.general.clearContents();NSPasteboard.general.setString(text,forType:.string)
        }
        if notify {showFeedback("Copied")}
    }
    func sendClipboard(_ text: String,pasteKeys: [UInt32]?=nil,human: Bool=true) throws {
        guard active,let worker else {throw DeckError("Desktop is not connected")}
        guard text.utf8.count<=Int(DECK_CLIPBOARD_LIMIT) else {throw DeckError("Clipboard text exceeds 1 MB")}
        guard !clipboardInFlight else {throw DeckError("Clipboard transfer is still in progress")}
        cancelImageTransfer()
        if human {humanInput();releaseInput()}
        clipboardInFlight=true;clipboardPasteKeys=pasteKeys;clipboardStatus="Sending"
        clipboardFeedback=pasteKeys==nil ? "Clipboard sent":"Paste sent"
        worker.enqueue(.clipboard(text))
    }
    func clipboardSent(_ result: Int) {
        guard clipboardInFlight else {return}
        clipboardInFlight=false
        let keys=clipboardPasteKeys;clipboardPasteKeys=nil
        guard result>0 else {clipboardStatus=result == -1 ? "Server clipboard supports Latin-1 text only":"Clipboard transfer failed";showFeedback(clipboardStatus);return}
        clipboardStatus="Sent"
        if let keys,!sendChord(keys) {return}
        showFeedback(clipboardFeedback)
    }
    func pasteMacClipboard(keys: [UInt32]?=[0xffe3,0x76]) {
        do {if let image=try ImageClipboard.read(.general) {pasteImage(image,keys:keys);return}}
        catch {showFeedback(error.localizedDescription);return}
        guard let text=NSPasteboard.general.string(forType:.string) else {showFeedback("No text in Mac clipboard");return}
        do {try sendClipboard(text,pasteKeys:keys)} catch {showFeedback(error.localizedDescription)}
    }
    @discardableResult func sendChord(_ keys: [UInt32]) -> Bool {
        let events=keys.map{VNCWorker.Event.key($0,true)}+keys.reversed().map{VNCWorker.Event.key($0,false)}
        guard worker?.enqueueBatch(events)==true else {showFeedback("Input queue is full");return false};return true
    }
    func shortcut(_ keys: [UInt32]) {
        guard active else {showFeedback("Desktop is not connected");return}
        humanInput();releaseInput();inputView?.window?.makeFirstResponder(inputView)
        if keys.contains(0xffe3),keys.contains(0x63) {copyFeedbackIntent.request()}
        sendChord(keys)
    }
    func toggleModifier(_ key: UInt32) {
        guard active else {return}
        humanInput();inputView?.window?.makeFirstResponder(inputView)
        if heldModifiers.remove(key) != nil {self.key(key,down:false)}
        else {heldModifiers.insert(key);self.key(key,down:true)}
    }
}
struct RemoteInputMenu: View {
    @ObservedObject var session: DesktopSession
    @AppStorage("syncFocusedClipboard") private var receiveClipboard=true
    var body: some View {
        Menu {
            Button("Paste Mac clipboard · ⌘V"){session.pasteMacClipboard()}
            Button("Paste into terminal · Ctrl+Shift+V"){session.pasteMacClipboard(keys:[0xffe3,0xffe1,0x76])}
            Button("Send Mac clipboard without pasting"){session.pasteMacClipboard(keys:nil)}
            if session.imageUploading {Button("Cancel image transfer"){session.cancelImageTransfer()}}
            Button("Copy remote clipboard to Mac"){session.copyRemoteClipboard()}.disabled(session.remoteClipboard==nil)
            Toggle("Receive clipboard from focused desktop",isOn:$receiveClipboard)
            Divider()
            Button("Copy · Ctrl+C"){session.shortcut([0xffe3,0x63])}
            Button("Alt+Tab"){session.shortcut([0xffe9,0xff09])}
            Button("Ctrl+Alt+Delete"){session.shortcut([0xffe3,0xffe9,0xffff])}
            Button("Escape"){session.shortcut([0xff1b])}
            Button("Super / Windows"){session.shortcut([0xffeb])}
            Menu("Hold modifier") {
                modifier("Alt",0xffe9);modifier("Ctrl",0xffe3);modifier("Shift",0xffe1);modifier("Super",0xffeb)
                Divider();Button("Release all keys"){session.releaseInput()}
            }
        } label:{Image(systemName:"keyboard").foregroundStyle(session.tint.opacity(session.heldModifiers.isEmpty ? 0.8:1))}
            .help("Keyboard and clipboard").disabled(!session.active)
    }
    private func modifier(_ name: String,_ key: UInt32) -> some View {
        Toggle(name,isOn:Binding(get:{session.heldModifiers.contains(key)},set:{_ in session.toggleModifier(key)}))
    }
}
struct FeedbackToast: View {
    @ObservedObject var session: DesktopSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Group {if let feedback=session.feedback {
            Text(feedback.text).font(.system(size:11,weight:.medium)).lineLimit(2)
                .padding(.horizontal,10).padding(.vertical,6)
                .background(DeckTheme.panel.opacity(0.96),in:Capsule())
                .overlay(Capsule().strokeBorder(session.tint.opacity(0.5),lineWidth:1))
                .shadow(color:.black.opacity(0.35),radius:6,y:2)
                .id(feedback.id).transition(.opacity.combined(with:.move(edge:.bottom)))
        }}.allowsHitTesting(false).animation(reduceMotion ? nil:.easeOut(duration:0.16),value:session.feedback?.id)
    }
}
