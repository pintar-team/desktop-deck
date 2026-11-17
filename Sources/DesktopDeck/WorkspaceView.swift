import SwiftUI
import AppKit
import DeckCore

struct WorkspaceView: View {
    @ObservedObject var model: WorkspaceModel
    @State private var editPreset=false
    @AppStorage("showThumbnails") private var showThumbnails=false
    @AppStorage("previewSmoothing") private var previewSmoothing=true
    @AppStorage("showHostMetrics") private var showHostMetrics=true
    @AppStorage("chromeMode") private var chromeMode="normal"
    @AppStorage("sidebarVisible") private var sidebarVisible=true
    @AppStorage("sidebarWidth") private var sidebarWidth=205.0
    @State private var revealChrome=false
    @State private var pinnedChrome=false
    @State private var hideTask: Task<Void,Never>?
    @State private var dragOrigin: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var toolbarVisible: Bool {chromeMode=="normal" || revealChrome}
    private var activeTint: Color {model.focused?.tint ?? DeckTheme.accent}
    var body: some View {
        HStack(spacing:0) {
            if sidebarVisible {
                sidebar.frame(width:sidebarWidth)
                Rectangle().fill(DeckTheme.border.opacity(0.6)).frame(width:1)
                    .gesture(DragGesture().onChanged {v in
                        if dragOrigin==nil {dragOrigin=sidebarWidth}
                        sidebarWidth=min(300,max(170,(dragOrigin ?? sidebarWidth)+v.translation.width))
                    }.onEnded{_ in dragOrigin=nil})
            }
            VStack(spacing:0) {
                if toolbarVisible {toolbar.zIndex(2).transition(.move(edge:.top).combined(with:.opacity))}
                if !model.error.isEmpty {errorBanner}
                content.clipped().zIndex(0)
            }.frame(maxWidth:.infinity,maxHeight:.infinity).background(DeckTheme.background)
        }
        .overlay(alignment:.topTrailing) {
            if !toolbarVisible {
                HStack(spacing:3) {
                    Button {sidebarVisible.toggle()} label:{Image(systemName:"sidebar.left")}.help("Connections sidebar")
                    Button {hideTask?.cancel();pinnedChrome=true;withAnimation{revealChrome=true}} label:{Image(systemName:"chevron.down")}.help("Show toolbar and view modes")
                }.buttonStyle(.borderless).controlSize(.mini).foregroundStyle(activeTint).padding(.horizontal,5).frame(height:24)
                    .background(DeckTheme.panel.opacity(0.92),in:RoundedRectangle(cornerRadius:4)).padding(4)
            }
        }
        .overlay(alignment:.top) {
            if !toolbarVisible {Color.clear.frame(height:5).contentShape(Rectangle()).onHover {if $0 {withAnimation{revealChrome=true}}}.padding(.trailing,70)}
        }
        .background(WindowBackdrop(hideButtons:chromeMode != "normal"))
        .tint(activeTint)
        .ignoresSafeArea(.container,edges:.top).toolbarVisibility(.hidden,for:.windowToolbar)
        .animation(reduceMotion ? nil:.smooth(duration:0.18),value:toolbarVisible)
        .overlay(alignment:.bottom) {if let s=model.focused {FeedbackToast(session:s).padding(.bottom,14)}}
        .onChange(of:chromeMode){_,_ in revealChrome=false;pinnedChrome=false;hideTask?.cancel()}
        .sheet(item:$model.profileDraft){ProfileEditor(model:model,profile:$0.profile,duplicateSource:$0.duplicateSource)}
        .sheet(isPresented:$editPreset){WorkspacePresetEditor(model:model)}
    }
    private var content: some View {
        Group {
            if model.visible.isEmpty {
                ContentUnavailableView("Your remote workspace",systemImage:"display.2",description:Text("Add connections and choose a workspace."))
            } else if model.viewMode == .overview {
                CompactGrid(model:model)
            } else if let s=model.focused {
                VStack(spacing:0) {
                    DesktopPanel(session:s,model:model)
                    if showThumbnails {ScrollView(.horizontal) {
                        HStack(spacing:0){ForEach(model.visible){DesktopTile(session:$0,model:model,compact:true).frame(width:180,height:112)}}
                    }.frame(height:112).background(DeckTheme.background)}
                }
            }
        }.frame(maxWidth:.infinity,maxHeight:.infinity)
    }
    private var sidebar: some View {
        VStack(spacing:0) {
            TextField("Find connections",text:$model.search).textFieldStyle(.roundedBorder)
                .padding(.horizontal,8).padding(.top,chromeMode=="normal" ? 34:8).padding(.bottom,5)
            List {
                ForEach(model.sidebarSessions) {s in
                    SidebarRow(session:s,selected:model.focused?.id==s.id).contentShape(Rectangle())
                        .onTapGesture {
                            model.updateWorkspace{if !$0.profiles.contains(s.id){$0.profiles.append(s.id)};$0.focused=s.id}
                            if model.workspace.focusMode && !s.profile.hasVNC {model.setViewMode(.terminal)}
                        }
                        .contextMenu {
                            ConnectionActions(session:s,model:model)
                            Divider();Button("Edit connection"){model.editProfile(s)};Button("Duplicate connection"){model.duplicateProfile(s)};ConnectionOrderMenu(session:s,model:model);ProfileColorMenu(session:s,model:model)
                            Button("Remove connection",role:.destructive){model.delete(s)}
                        }
                }.onMove(perform:model.moveSidebar)
            }.listStyle(.sidebar).scrollContentBackground(.hidden)
            HStack {
                Button {model.editProfile()} label:{Label("Connection",systemImage:"plus")}
                Spacer();Text("\(model.sessions.filter(\.isOnline).count) online").font(.caption).foregroundStyle(.secondary)
            }.buttonStyle(.borderless).padding(9)
        }.background(DeckTheme.panel)
    }
    private var toolbar: some View {
        HStack(spacing:5) {
            Button {sidebarVisible.toggle()} label:{Image(systemName:"sidebar.left")}.help("Connections sidebar")
            if model.saved.workspaces.count>1 {
                ScrollView(.horizontal,showsIndicators:false){HStack(spacing:2){ForEach(model.saved.workspaces){p in
                    Button {model.saved.selectedWorkspace=p.id;model.updateRenderingRates();model.persist()} label:{
                        Text(p.name).font(.system(size:11,weight:.medium)).lineLimit(1).padding(.horizontal,6).frame(height:22)
                            .background(p.id==model.saved.selectedWorkspace ? activeTint.opacity(0.16):.clear,in:RoundedRectangle(cornerRadius:3))
                    }.buttonStyle(.plain)
                }}}.frame(maxWidth:220)
            }
            ModeButtons(mode:model.viewMode,supportsSSH:model.focused?.profile.usesSSH ?? false,supportsVNC:model.focused?.profile.hasVNC ?? false,tint:model.focused?.tint ?? DeckTheme.accent,select:model.setViewMode)
            if model.viewMode == .overview {
                Picker("Grid columns",selection:Binding(get:{model.workspace.gridMode ?? 0},set:{v in model.updateWorkspace{$0.gridMode=v}})) {
                    Text("Fit all").tag(0);ForEach([2,3,4,5],id:\.self){Text("\($0) × N").tag($0)}
                }.labelsHidden().fixedSize()
                Spacer(minLength:4)
            } else if let s=model.focused {
                FocusedConnectionControls(session:s,model:model)
            }
            Rectangle().fill(DeckTheme.border).frame(width:1,height:14)
            Toggle(isOn:$showThumbnails){Image(systemName:"film")}.toggleStyle(.button).disabled(model.viewMode == .overview)
                .help("Show other desktops · independent of view mode")
            Button {model.saved.workspaces.append(WorkspacePreset(name:"Workspace \(model.saved.workspaces.count+1)",profiles:[]));model.saved.selectedWorkspace=model.saved.workspaces.last?.id;model.persist();editPreset=true} label:{Image(systemName:"plus")}.help("New workspace")
            Button {editPreset=true} label:{Image(systemName:"square.grid.2x2")}.help("Edit workspace connections and order")
            Menu {
                Toggle("Auto-hide toolbar · ⌘⇧I",isOn:Binding(get:{chromeMode != "normal"},set:{chromeMode=$0 ? "auto":"normal"}))
                Toggle("Soften preview transitions",isOn:$previewSmoothing)
                Toggle("Host CPU and disk · SSH",isOn:$showHostMetrics)
                Divider();Button("Import configuration…"){model.importConfigurationFile()};Button("Export configuration…"){model.exportConfiguration()}
                Divider();Button("Connect workspace"){model.visible.filter{!$0.isOnline}.forEach{model.connect($0)}}
                Button("Disconnect workspace"){model.visible.forEach{model.disconnect($0)}}
            } label:{Image(systemName:"ellipsis")}.help("Workspace actions and preferences")
            Button {model.toggleFullScreen()} label:{Image(systemName:model.isFullScreen ? "arrow.down.right.and.arrow.up.left":"arrow.up.left.and.arrow.down.right")}.help("Full screen · ⌃⌘F")
            if chromeMode != "normal" {Button {revealChrome=false;pinnedChrome=false} label:{Image(systemName:"chevron.up")}.help("Hide toolbar")}
        }.buttonStyle(.borderless).controlSize(.mini).font(.system(size:12))
            .foregroundStyle(activeTint).tint(activeTint)
            .padding(.leading,chromeMode=="normal" && !sidebarVisible ? 80:5).padding(.trailing,5).frame(height:30).background(DeckTheme.panel)
            .overlay(alignment:.bottom){activeTint.opacity(0.2).frame(height:1)}
            .onHover {inside in
                hideTask?.cancel()
                if !inside && chromeMode != "normal" && !pinnedChrome {
                    hideTask=Task {try? await Task.sleep(nanoseconds:1_500_000_000);if !Task.isCancelled{withAnimation{revealChrome=false}}}
                }
            }
    }
    private var errorBanner: some View {
        HStack {Text(model.error).font(.caption).textSelection(.enabled);Spacer();Button{model.error=""}label:{Image(systemName:"xmark")}}.padding(6).background(.orange.opacity(0.12))
    }
}
