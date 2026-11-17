import SwiftUI
import DeckCore

struct ModeButtons: View {
    let mode: ViewMode
    let supportsSSH: Bool
    let supportsVNC: Bool
    let tint: Color
    let select: (ViewMode)->Void
    var body: some View {
        HStack(spacing:0){ForEach(ViewMode.allCases){item in
            Button {select(item)} label:{
                Image(systemName:item.symbol).font(.system(size:12,weight:.medium)).frame(width:27,height:23)
                    .foregroundStyle(tint.opacity(mode==item ? 1:0.45))
                    .background(mode==item ? tint.opacity(0.16):.clear,in:RoundedRectangle(cornerRadius:3))
            }.buttonStyle(.plain).disabled((item.showsTerminal && !supportsSSH) || (item.showsDesktop && !supportsVNC)).help(item.title)
                .accessibilityLabel(item.title).accessibilityValue(mode==item ? "Selected":"")
        }}.fixedSize()
    }
}
struct FocusedConnectionControls: View {
    @ObservedObject var session: DesktopSession
    @ObservedObject var model: WorkspaceModel
    var body: some View {
      HStack(spacing:5) {
        Text(session.profile.name).font(.system(size:11,weight:.semibold)).foregroundStyle(session.tint).lineLimit(1)
        if session.profile.sessionManager {sessionMenu.fixedSize()}
        Spacer(minLength:4)
        HStack(spacing:5) {
            if model.viewMode.showsDesktop {
                RemoteInputMenu(session:session).fixedSize()
                Menu {
                    Button("Fit entire desktop"){session.zoom=1;session.pan = .zero}
                    Button("100% pixels") {if let f=session.frame {session.zoom=1/min(session.viewport.width/Double(f.width),session.viewport.height/Double(f.height));session.pan = .zero}}
                    ForEach([1.5,2,3,4],id:\.self){z in Button("\(Int(z*100))% of fit"){session.zoom=z}}
                } label:{Image(systemName:"plus.magnifyingglass")}.help("Zoom").fixedSize()
                Picker("Quality",selection:$session.profile.quality){Text("Auto").tag("auto");Text("Text").tag("text");Text("Balanced").tag("balanced");Text("Economy").tag("economy")}
                    .labelsHidden().fixedSize().onChange(of:session.profile.quality){_,_ in session.quality();model.persist()}
                ResolutionControl(session:session).fixedSize()
            }
            Menu {ConnectionActions(session:session,model:model)} label:{
                Image(systemName:session.isOnline ? "link":"arrow.clockwise").foregroundStyle(session.isOnline ? session.tint:.orange)
            }.help(session.tooltip).fixedSize()
        }.fixedSize()
      }
    }
    private var sessionMenu: some View {
        Menu(session.profile.display.isEmpty ? "Screen":"Screen \(session.profile.display)") {
            if let previous=session.previousDisplay {Button("Previous desktop \(previous)"){model.selectSession(session,display:previous)};Divider()}
            ForEach(session.remoteSessions,id:\.display){remote in
                Button(remote.display){model.selectSession(session,display:remote.display)}
            }
            Divider();Button("Refresh sessions"){Task{await model.refreshSessions(session)}}
            Button("Create new desktop"){Task{do{try await model.createSession(session)}catch{session.detail=error.localizedDescription}}}
        }.task(id:session.id){await model.refreshSessions(session)}
    }
}
struct ConnectionActions: View {
    @ObservedObject var session: DesktopSession
    @ObservedObject var model: WorkspaceModel
    var body: some View {
        Button(session.wantsConnection || session.isOnline ? "Reconnect now":"Connect"){model.connect(session)}
        if session.wantsConnection || session.isOnline {Button("Disconnect"){model.disconnect(session)}}
        if session.attemptNumber>0 {Divider();Text("Attempt \(session.attemptNumber) of \(ConnectionLimits.attempts)")}
        if !session.lastError.isEmpty {Text(session.lastError)}
    }
}
struct ConnectionOrderMenu: View {
    let session: DesktopSession
    @ObservedObject var model: WorkspaceModel
    private var index: Int? {model.workspace.profiles.firstIndex(of:session.id)}
    var body: some View {
        Menu("Order") {
            Button("Move earlier"){model.moveInWorkspace(session.id,by:-1)}.disabled(index==nil || index==0)
            Button("Move later"){model.moveInWorkspace(session.id,by:1)}.disabled(index==nil || index==model.workspace.profiles.count-1)
        }
    }
}
