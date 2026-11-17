import SwiftUI
import AppKit
import DeckCore

@main struct DesktopDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var model=WorkspaceModel()
    var body: some Scene {
        WindowGroup("Desktop Deck",id:"main") {
            WorkspaceView(model:model).frame(minWidth:860,minHeight:580)
                .preferredColorScheme(.dark).tint(DeckTheme.accent)
                .font(.system(.body,design:.rounded))
                .onAppear { delegate.model=model; model.start() }
        }.defaultSize(width:1440,height:900).windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing:.newItem) {}
            CommandGroup(after:.newItem) {
                Button("Import configuration…"){model.importConfigurationFile()}
                Button("Export configuration…"){model.exportConfiguration()}
            }
            CommandMenu("Connection") {
                Button("Connect all in workspace") { model.visible.forEach{model.connect($0)} }
                Button("Disconnect workspace") { model.visible.forEach{model.disconnect($0)} }
                Button("Full screen"){model.toggleFullScreen()}.keyboardShortcut("f",modifiers:[.control,.command])
                Divider()
                Button("Overview / Focus") {model.setViewMode(model.viewMode == .overview ? ViewMode(rawValue:model.focused?.surfaceMode ?? "desktop") ?? .desktop:.overview,focusKeyboard:true)}.keyboardShortcut("g",modifiers:[.command,.shift])
                Button("Desktop / Terminal") {
                    model.setViewMode(model.viewMode == .terminal ? .desktop:.terminal,focusKeyboard:true)
                }.keyboardShortcut("t",modifiers:[.command,.shift])
                Button("Auto-hide / Show interface") {
                    let mode=UserDefaults.standard.string(forKey:"chromeMode") ?? "normal"
                    UserDefaults.standard.set(mode=="normal" ? "auto":"normal",forKey:"chromeMode")
                }.keyboardShortcut("i",modifiers:[.command,.shift])
            }
        }
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: WorkspaceModel?
    private var termination: DispatchSourceSignal?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { model?.stop() }
    func applicationDidResignActive(_ notification: Notification) { model?.sessions.forEach{$0.releaseInput()} }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let icon=Bundle.main.url(forResource:"AppIcon",withExtension:"icns") {NSApplication.shared.applicationIconImage=NSImage(contentsOf:icon)}
        for (name,enabled) in [(NSWindow.didEnterFullScreenNotification,true),(NSWindow.didExitFullScreenNotification,false)] {
            NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main) {[weak self] _ in Task {@MainActor in self?.model?.isFullScreen=enabled}}
        }
        signal(SIGTERM,SIG_IGN)
        termination=DispatchSource.makeSignalSource(signal:SIGTERM,queue:.main)
        termination?.setEventHandler { NSApplication.shared.terminate(nil) }; termination?.resume()
        NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in guard let model=self?.model else { return }; model.sessions.filter{$0.desired && !$0.active && !$0.needsAction}.forEach{model.connect($0)} }
        }
    }
}
