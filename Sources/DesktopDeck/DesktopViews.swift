import SwiftUI
import AppKit
import DeckCore

struct SidebarRow: View {
    @ObservedObject var session: DesktopSession
    let selected: Bool
    var body: some View {
        HStack(spacing:8) {
            StatusDot(session:session)
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
struct StatusDot: View {
    @ObservedObject var session: DesktopSession
    var body: some View {
        Circle().fill(session.isOnline ? session.tint:session.needsAction ? .orange:session.wantsConnection ? .yellow:.gray)
            .frame(width:6,height:6).shadow(color:.black.opacity(0.8),radius:2).help(session.diagnosticTooltip)
    }
}
struct DesktopTile: View {
    @ObservedObject var session: DesktopSession
    @ObservedObject var model: WorkspaceModel
    var compact=false
    @State private var dropTarget=false
    @State private var tileWidth: CGFloat=1
    var body: some View {
        ZStack(alignment:.topLeading) {
            Color.black
            if session.profile.hasVNC {RemoteSurface(session:session,interactive:false).allowsHitTesting(false)}
            else {TerminalPreview(session:session).allowsHitTesting(false)}
            if session.profile.hasVNC && session.frame==nil {
                VStack(spacing:8) {
                    Image(systemName:"display").font(.system(size:26,weight:.light)).foregroundStyle(session.tint.opacity(0.5))
                    if session.desired && !session.needsAction {ProgressView().controlSize(.small)}
                    if session.needsAction || !session.desired {Button(session.needsAction ? "Try again":"Connect"){model.connect(session)}.buttonStyle(.bordered).controlSize(.small)}
                }.frame(minWidth:0,maxWidth:.infinity,minHeight:0,maxHeight:.infinity)
            }
            HStack(spacing:5) {
                StatusDot(session:session)
                Text(session.profile.name).font(.system(size:12,weight:.semibold,design:.rounded)).foregroundStyle(session.tint)
                if !session.isOnline {Text(session.connectionSummary).font(.system(size:10)).foregroundStyle(.white.opacity(0.8))}
            }.lineLimit(1).padding(5).shadow(color:.black,radius:2,x:0,y:1)
                .onDrag{NSItemProvider(object:session.id.uuidString as NSString)}
        }.contentShape(Rectangle()).onTapGesture {model.updateWorkspace{$0.focused=session.id};model.setViewMode(session.profile.hasVNC ? .desktop:.terminal)}
            .overlay(alignment:.bottomLeading){HostMetricsReadout(session:session).padding(5).allowsHitTesting(false)}
            .overlay(Rectangle().strokeBorder(session.tint.opacity(model.focused?.id==session.id || dropTarget ? 1:0.45),lineWidth:model.focused?.id==session.id || dropTarget ? 2:1))
            .onGeometryChange(for:CGFloat.self){$0.size.width} action:{tileWidth=$0}
            .dropDestination(for:String.self) {items,location in guard let value=items.first,let source=UUID(uuidString:value) else {return false};return model.moveInWorkspace(source,relativeTo:session.id,after:location.x>tileWidth/2)} isTargeted:{dropTarget=$0}
            .contextMenu {ConnectionActions(session:session,model:model);Divider();Button("Open terminal"){_=model.openTerminal(session)}.disabled(!session.profile.usesSSH);Button("Edit connection"){model.editProfile(session)};Button("Duplicate connection"){model.duplicateProfile(session)};ConnectionOrderMenu(session:session,model:model);ProfileColorMenu(session:session,model:model)}
            .help(session.tooltip)
    }
}
struct TerminalPreview: View {
    @ObservedObject var session: DesktopSession
    var body: some View {
        TimelineView(.periodic(from:.now,by:1)) {_ in
            if let tab=session.selectedTab {
                Text(tab.read(limit:2400)).font(.system(size:8,design:.monospaced)).foregroundStyle(session.tint.opacity(0.8))
                    .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.bottomLeading).padding(6).padding(.top,20).clipped()
            } else {Image(systemName:"terminal").font(.system(size:28,weight:.light)).foregroundStyle(session.tint.opacity(0.5)).frame(maxWidth:.infinity,maxHeight:.infinity)}
        }
    }
}
struct DesktopPanel: View {
    @ObservedObject var session: DesktopSession
    @ObservedObject var model: WorkspaceModel
    var body: some View {
        VStack(spacing:0) {
            if model.viewMode.showsDesktop {
                ZStack {
                    Color.black;RemoteSurface(session:session,interactive:true)
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
            if model.viewMode.showsTerminal {TerminalPanel(session:session,model:model,fullHeight:model.viewMode == .terminal)}
        }.onDisappear{session.releaseInput()}
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
    var fullHeight=false
    @State private var dragOrigin: CGFloat?
    var body: some View {
        VStack(spacing:0) {
            if !fullHeight {Rectangle().fill(DeckTheme.border).frame(height:3).cursorResize().gesture(DragGesture().onChanged{v in
                if dragOrigin==nil {dragOrigin=session.terminalHeight}
                session.terminalHeight=min(700,max(120,(dragOrigin ?? session.terminalHeight)-v.translation.height))
            }.onEnded{_ in dragOrigin=nil})}
            HStack(spacing:4) {
                ScrollView(.horizontal,showsIndicators:false){HStack(spacing:2){ForEach(session.terminals){tab in
                    TerminalTabButton(tab:tab,selected:session.selectedTerminal==tab.id,tint:session.tint){session.selectedTerminal=tab.id}
                }}}
                Button{_=model.openTerminal(session)}label:{Image(systemName:"plus")}.help("New terminal tab")
                if let tab=selected {TerminalActions(tab:tab)}
            }.buttonStyle(.borderless).controlSize(.mini).padding(.horizontal,5).frame(height:24).background(DeckTheme.panel)
            if let tab=selected {TerminalSurface(tab:tab).frame(height:fullHeight ? nil:session.terminalHeight).frame(maxHeight:fullHeight ? .infinity:nil)}
            else {
                VStack(spacing:10) {
                    Image(systemName:"terminal").font(.system(size:28,weight:.light)).foregroundStyle(session.tint.opacity(0.6))
                    Button("Connect"){_=model.openTerminal(session)}.controlSize(.small)
                }.frame(maxWidth:.infinity,maxHeight:fullHeight ? .infinity:nil).frame(height:fullHeight ? nil:session.terminalHeight)
            }
        }
    }
    private var selected: TerminalTab? {session.selectedTab}
}
struct TerminalTabButton: View {
    @ObservedObject var tab: TerminalTab
    let selected: Bool
    let tint: Color
    let select: ()->Void
    var body: some View {
        Button(action:select){
            HStack(spacing:4){
                Circle().fill(tab.status.hasPrefix("Connected") ? tint:.orange).frame(width:4,height:4)
                Text(tab.title).font(.system(size:11,weight:selected ? .semibold:.regular)).lineLimit(1)
            }.padding(.horizontal,5).frame(height:22).foregroundStyle(selected ? tint:.primary)
                .overlay(alignment:.bottom){Rectangle().fill(selected ? tint:.clear).frame(height:1)}
        }.buttonStyle(.plain).help(tab.status)
    }
}
struct TerminalActions: View {
    @ObservedObject var tab: TerminalTab
    var body: some View {Menu{Text(tab.status);Divider();Button("Reconnect"){tab.detach();tab.connect()};Button("Detach"){tab.detach()};Button("End terminal",role:.destructive){Task{do{try await tab.end()}catch{tab.status=error.localizedDescription}}}}label:{Image(systemName:"ellipsis")}.help(tab.status)}
}
extension View {
    func cursorResize() -> some View {onHover{if $0 {NSCursor.resizeUpDown.push()}else{NSCursor.pop()}}}
}
