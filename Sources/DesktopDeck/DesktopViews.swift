import SwiftUI
import AppKit
import DeckCore

struct SidebarRow: View {
    @ObservedObject var session: DesktopSession
    let selected: Bool
    var body: some View {
        HStack(spacing:8) {
            ConnectionMark(state:session.indicator,tint:session.tint)
            VStack(alignment:.leading,spacing:2) {
                Text(session.profile.name).fontWeight(selected ? .semibold:.regular).foregroundStyle(session.tint).lineLimit(1)
                HStack(spacing:4) {
                    Text(session.isOnline ? session.profile.group:session.connectionSummary).font(.system(size:10)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength:0)
                    HostMetricsReadout(session:session,sidebar:true).layoutPriority(1)
                }
            }.frame(maxWidth:.infinity,alignment:.leading)
        }.padding(.vertical,4).padding(.horizontal,4).background(selected ? session.tint.opacity(0.12):.clear,in:RoundedRectangle(cornerRadius:4)).help(session.tooltip)
    }
}
struct DesktopTile: View {
    @ObservedObject var session: DesktopSession
    @ObservedObject var model: WorkspaceModel
    var gridReorder = true
    @State private var dropTarget=false
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment:.topLeading) {
                Button(action:open) {
                    ZStack {
                        Color.black
                        if session.profile.hasVNC {RemoteSurface(session:session,interactive:false).allowsHitTesting(false)}
                        else {TerminalPreview(session:session).allowsHitTesting(false)}
                        if !session.isOnline {Color.black.opacity(0.32).allowsHitTesting(false)}
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Open \(session.profile.name)")
                if session.profile.hasVNC && session.frame==nil {
                    VStack(spacing:8) {
                        if geo.size.height>=92 {Image(systemName:"display").font(.system(size:26,weight:.light)).foregroundStyle(session.tint.opacity(0.5)).allowsHitTesting(false)}
                        if session.desired && !session.needsAction {ProgressView().controlSize(.small).allowsHitTesting(false)}
                        if geo.size.height>=48 && (session.needsAction || !session.desired) {Button(session.needsAction ? "Try again":"Connect"){model.connect(session)}.buttonStyle(.bordered).controlSize(.small)}
                    }.padding(.top,geo.size.height<92 ? 16:0).frame(minWidth:0,maxWidth:.infinity,minHeight:0,maxHeight:.infinity)
                }
            }.frame(width:geo.size.width,height:geo.size.height).clipped()
                .overlay {TileChrome(session:session,emphasized:model.focused?.id==session.id || dropTarget,gridReorder:gridReorder,open:open)}
                .dropDestination(for:String.self) {items,location in guard gridReorder,let value=items.first,let source=UUID(uuidString:value) else {return false};return model.moveInWorkspace(source,relativeTo:session.id,after:location.x>geo.size.width/2)} isTargeted:{dropTarget=gridReorder && $0}
                .contextMenu {ConnectionActions(session:session,model:model);Divider();Button("Open terminal"){_=model.openTerminal(session)}.disabled(!session.profile.usesSSH);Button("Edit connection"){model.editProfile(session)};Button("Duplicate connection"){model.duplicateProfile(session)};ConnectionOrderMenu(session:session,model:model);ProfileColorMenu(session:session,model:model)}
                .help([session.tooltip,session.activity?.hint].compactMap{$0}.joined(separator:"\n"))
        }
    }
    private func open() {
        model.updateWorkspace{$0.focused=session.id}
        model.setViewMode(session.profile.hasVNC ? .desktop:.terminal,focusKeyboard:true)
    }
}
struct DesktopPanel: View {
    @ObservedObject var session: DesktopSession
    @ObservedObject var model: WorkspaceModel
    var body: some View {
        GeometryReader { geometry in VStack(spacing:0) {
            if model.viewMode.showsDesktop {
                ZStack {
                    Color.black;RemoteSurface(session:session,interactive:true,focusRequest:model.keyboardFocus(for:session.id))
                    if !session.active {
                        if session.frame==nil {
                            VStack(spacing:10) {
                                Image(systemName:"display").font(.system(size:30,weight:.light)).foregroundStyle(session.tint.opacity(0.6))
                                if session.desired && !session.needsAction {ProgressView().controlSize(.small)}
                                connectionBanner
                            }.frame(maxWidth:440).padding(16)
                        } else {VStack {Spacer();connectionBanner.padding(9).background(DeckTheme.panel.opacity(0.96),in:RoundedRectangle(cornerRadius:6)).padding(12)}.frame(maxWidth:520)}
                    }
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
            }
            if model.viewMode.showsTerminal {TerminalPanel(session:session,model:model,splitAvailable:model.viewMode == .split ? geometry.size.height:nil)}
        }.frame(width:geometry.size.width,height:geometry.size.height) }.onDisappear{session.releaseInput()}
    }
    private var connectionBanner: some View {
        Group {
            if session.frame==nil {
                VStack(spacing:10) {connectionStatus;connectionButton}.multilineTextAlignment(.center)
            } else {HStack(spacing:8) {connectionStatus;connectionButton}}
        }.buttonStyle(.borderless)
    }
    private var connectionStatus: some View {
        VStack(alignment:session.frame==nil ? .center:.leading,spacing:2) {
            Text(session.connectionSummary).font(.caption.weight(.medium)).lineLimit(1)
            if !session.lastError.isEmpty {Text(session.lastError).font(.caption2).foregroundStyle(.secondary).lineLimit(2).help(session.lastError)}
        }
    }
    private var connectionButton: some View {
        Button(session.needsAction ? "Try again":session.desired ? "Retry now":"Connect"){model.connect(session)}.fixedSize()
    }
}
struct TerminalPanel: View {
    @ObservedObject var session: DesktopSession
    @ObservedObject var model: WorkspaceModel
    var splitAvailable: CGFloat?
    @State private var dragOrigin: CGFloat?
    @State private var closingTab: TerminalTab?
    private var fittedHeight: CGFloat? {
        guard let splitAvailable else {return nil}
        return CGFloat(SplitLayout.terminalHeight(preferred:session.terminalHeight,available:splitAvailable))
    }
    var body: some View {
        VStack(spacing:0) {
            if let splitAvailable {Color.clear.frame(height:SplitLayout.dividerHeight)
                .overlay(Rectangle().fill(DeckTheme.border).frame(height:1).allowsHitTesting(false))
                .contentShape(Rectangle()).cursorResize().gesture(DragGesture(minimumDistance:0,coordinateSpace:.global).onChanged{v in
                let origin=dragOrigin ?? SplitLayout.terminalHeight(preferred:session.terminalHeight,available:splitAvailable)
                dragOrigin=origin;session.terminalHeight=SplitLayout.terminalHeight(preferred:origin-v.translation.height,available:splitAvailable)
            }.onEnded{_ in dragOrigin=nil})}
            HStack(spacing:4) {
                ScrollView(.horizontal,showsIndicators:false){HStack(spacing:2){ForEach(session.terminals){tab in
                    TerminalTabButton(tab:tab,selected:session.selectedTerminal==tab.id,tint:session.tint,previousEndpoint:!tab.profile.hasSameTerminalConnection(as:session.profile),select:{
                        session.selectedTerminal=tab.id;model.requestKeyboardFocus(terminal:true)
                    },close:{requestClose(tab)})
                }}}
                Button{_=model.openTerminal(session)}label:{Image(systemName:"plus")}.help("New terminal tab")
                if let tab=selected {TerminalActions(tab:tab,end:{requestClose(tab)})}
            }.buttonStyle(.borderless).controlSize(.mini).padding(.horizontal,5).frame(height:SplitLayout.tabBarHeight).background(DeckTheme.panel)
            Group {if let tab=selected {TerminalSurface(tab:tab,focusRequest:model.keyboardFocus(for:session.id,terminal:tab.id))}
            else {
                VStack(spacing:10) {
                    Image(systemName:"terminal").font(.system(size:28,weight:.light)).foregroundStyle(session.tint.opacity(0.6))
                    Button("Connect"){_=model.openTerminal(session)}.controlSize(.small)
                }
            }}.frame(maxWidth:.infinity,maxHeight:.infinity).frame(height:fittedHeight)
        }.alert("Close terminal tab?",isPresented:Binding(get:{closingTab != nil},set:{if !$0 {closingTab=nil}}),presenting:closingTab) { tab in
            Button("End and Close",role:.destructive) {close(tab,endSession:true)}
            if tab.mayHaveTmuxSession {Button("Close Tab Only") {close(tab,endSession:false)}}
            Button("Cancel",role:.cancel) {}
        } message: { tab in
            Text(tab.mayHaveTmuxSession
                 ? "Close Tab Only leaves the tmux session running on the server and removes this tab."
                 : "Closing the tab ends its SSH shell.")
        }
    }
    private var selected: TerminalTab? {session.selectedTab}
    private func requestClose(_ tab: TerminalTab) {
        if tab.desired || tab.mayHaveTmuxSession {closingTab=tab}
        else {close(tab,endSession:false)}
    }
    private func close(_ tab: TerminalTab,endSession: Bool) {
        Task {
            do {try await model.closeTerminal(tab,in:session,endSession:endSession)}
            catch {session.showFeedback("Couldn’t close terminal")}
        }
    }
}
struct TerminalTabButton: View {
    @ObservedObject var tab: TerminalTab
    let selected: Bool
    let tint: Color
    var previousEndpoint=false
    let select: ()->Void
    let close: ()->Void
    @State private var hovering=false
    var body: some View {
        HStack(spacing:3) {
            Button(action:select){
                HStack(spacing:4){
                    ConnectionMark(state:tab.connection.indicator,tint:tint)
                    Text(tab.title).font(.system(size:11,weight:selected ? .semibold:.regular)).lineLimit(1)
                    if previousEndpoint {Text((tab.profile.sshUser.isEmpty ? "":tab.profile.sshUser+"@")+tab.profile.sshHost).font(.system(size:10)).foregroundStyle(.secondary).lineLimit(1)}
                }.padding(.leading,5).frame(height:22).foregroundStyle(selected ? tint:.primary)
            }.help(tab.status)
            Button(action:close) {
                Image(systemName:"xmark").font(.system(size:8,weight:.semibold))
                    .frame(width:16,height:18).contentShape(Rectangle())
                    .foregroundStyle(selected ? tint:Color.secondary)
                    .opacity(selected || hovering ? 1:0.65)
            }.disabled(tab.isEnding).help("Close terminal tab").accessibilityLabel("Close \(tab.title) tab")
        }.buttonStyle(.plain)
            .overlay(alignment:.bottom){Rectangle().fill(selected ? tint:.clear).frame(height:1).allowsHitTesting(false)}
            .onHover{hovering=$0}
    }
}
struct TerminalActions: View {
    @ObservedObject var tab: TerminalTab
    let end: ()->Void
    var body: some View {
        Menu {
            Text(tab.status);Divider()
            Button("Reconnect"){tab.detach();tab.connect()}
            Button("Detach"){tab.detach()}
            Button("End terminal",role:.destructive,action:end)
        } label:{Image(systemName:"ellipsis")}.disabled(tab.isEnding).help(tab.status)
    }
}
extension View {
    func cursorResize() -> some View {onHover{if $0 {NSCursor.resizeUpDown.push()}else{NSCursor.pop()}}}
}
