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
    @AppStorage("sidebarWidth") private var savedSidebarWidth=205.0
    @State private var resizingSidebarWidth: Double?
    @State private var revealChrome=false
    @State private var pinnedChrome=false
    @State private var fullScreenTopInset: CGFloat=0
    @State private var hideTask: Task<Void,Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var toolbarVisible: Bool {chromeMode=="normal" || revealChrome}
    private var activeTint: Color {model.focused?.tint ?? DeckTheme.accent}
    private var sidebarWidth: Double {SidebarResizeHandle.clamp(resizingSidebarWidth ?? savedSidebarWidth)}
    var body: some View {
      GeometryReader { geometry in
        let contentWidth=max(0,geometry.size.width-(sidebarVisible ? sidebarWidth+6:0))
        HStack(spacing:0) {
            if sidebarVisible {
                sidebar.frame(width:sidebarWidth)
                SidebarResizeHandle(width:sidebarWidth,change:{width in
                    var transaction=Transaction();transaction.disablesAnimations=true
                    withTransaction(transaction){resizingSidebarWidth=width}
                },finish:{width in savedSidebarWidth=width;resizingSidebarWidth=nil})
                    .frame(width:6).frame(maxHeight:.infinity)
                    .background(DeckTheme.panel)
                    .overlay(Rectangle().fill(DeckTheme.border.opacity(0.8)).frame(width:1).allowsHitTesting(false))
            }
            VStack(spacing:0) {
                if toolbarVisible {
                    toolbar.zIndex(2).transition(.move(edge:.top).combined(with:.opacity))
                }
                if !model.error.isEmpty {errorBanner}
                content.clipped().zIndex(0)
            }.frame(width:contentWidth,height:geometry.size.height)
                .background(DeckTheme.background)
        }.frame(width:geometry.size.width,height:geometry.size.height,alignment:.leading)
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
        .padding(.top,model.isFullScreen ? fullScreenTopInset:0)
        .background(WindowBackdrop(hideButtons:chromeMode != "normal",updateLayout:{fullScreen,inset in
            if model.isFullScreen != fullScreen {model.isFullScreen=fullScreen}
            if fullScreenTopInset != inset {fullScreenTopInset=inset}
        }))
        .tint(activeTint)
        .ignoresSafeArea(.container,edges:.top).toolbarVisibility(.hidden,for:.windowToolbar)
        .windowToolbarFullScreenVisibility(.onHover)
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
                        HStack(spacing:0){ForEach(model.visible){DesktopTile(session:$0,model:model).frame(width:180,height:112)}}
                    }.frame(height:112).background(DeckTheme.background)}
                }
            }
        }.frame(minWidth:0,maxWidth:.infinity,minHeight:0,maxHeight:.infinity)
    }
    private var sidebar: some View {
        VStack(spacing:0) {
            TextField("Find connections",text:$model.search).textFieldStyle(.roundedBorder)
                .padding(.horizontal,8).padding(.top,chromeMode=="normal" && !model.isFullScreen ? 34:8).padding(.bottom,5)
            List {
                ForEach(model.sidebarSessions) {s in
                    SidebarRow(session:s,selected:model.focused?.id==s.id).contentShape(Rectangle())
                        .onTapGesture {
                            model.updateWorkspace{if !$0.profiles.contains(s.id){$0.profiles.append(s.id)};$0.focused=s.id}
                            if model.workspace.focusMode && !s.profile.hasVNC {model.setViewMode(.terminal)}
                            model.requestKeyboardFocus()
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
            ModeButtons(mode:model.viewMode,supportsSSH:model.focused?.profile.usesSSH ?? false,supportsVNC:model.focused?.profile.hasVNC ?? false,tint:activeTint,select:{model.setViewMode($0,focusKeyboard:true)})
            GeometryReader { available in ScrollView(.horizontal,showsIndicators:false) {HStack(spacing:5) {
            if model.saved.workspaces.count>1 {
                ViewThatFits(in:.horizontal) {
                    HStack(spacing:2){ForEach(model.saved.workspaces){p in
                        Button {selectWorkspace(p)} label:{Text(p.name).lineLimit(1).padding(.horizontal,6).frame(height:22)
                            .background(p.id==model.saved.selectedWorkspace ? activeTint.opacity(0.16):.clear,in:RoundedRectangle(cornerRadius:3))}.buttonStyle(.plain)
                    }}.fixedSize()
                    Menu {ForEach(model.saved.workspaces){p in Button(p.name){selectWorkspace(p)}}} label:{Label("Workspaces",systemImage:"square.stack")}
                }.frame(maxWidth:min(220,available.size.width*0.3),alignment:.leading)
            }
            if model.viewMode == .overview {
                Picker("Grid columns",selection:Binding(get:{model.workspace.gridMode ?? 0},set:{v in model.updateWorkspace{$0.gridMode=v}})) {
                    Text("Fit all").tag(0);ForEach([2,3,4,5],id:\.self){Text("\($0) × N").tag($0)}
                }.labelsHidden().fixedSize()
                Spacer(minLength:4)
            } else if let s=model.focused {
                FocusedConnectionControls(session:s,model:model)
            }
            }.frame(minWidth:available.size.width,minHeight:30,alignment:.leading)}}
            Rectangle().fill(DeckTheme.border).frame(width:1,height:14).allowsHitTesting(false)
            Toggle(isOn:$showThumbnails){Image(systemName:"film")}.toggleStyle(.button).disabled(model.viewMode == .overview)
                .help("Show other desktops · independent of view mode")
            Button {model.saved.workspaces.append(WorkspacePreset(name:"Workspace \(model.saved.workspaces.count+1)",profiles:[]));model.saved.selectedWorkspace=model.saved.workspaces.last?.id;model.persist();editPreset=true} label:{Image(systemName:"plus")}.help("New workspace")
            Button {editPreset=true} label:{Image(systemName:"square.grid.2x2")}.help("Edit workspace connections and order")
            Menu {
                Toggle("Auto-hide toolbar · ⌘⇧I",isOn:Binding(get:{chromeMode != "normal"},set:{chromeMode=$0 ? "auto":"normal"}))
                Toggle("Soften preview transitions",isOn:$previewSmoothing)
                Toggle("Host CPU and disk · SSH",isOn:$showHostMetrics)
                Divider();Button("Import configuration…"){model.importConfigurationFile()};Button("Export configuration…"){model.exportConfiguration()}
                Divider();Button("Connect workspace"){model.visible.forEach(model.connectIfNeeded)}
                Button("Disconnect workspace"){model.visible.forEach{model.disconnect($0)}}
            } label:{Image(systemName:"ellipsis")}.help("Workspace actions and preferences")
            Button {model.toggleFullScreen()} label:{Image(systemName:model.isFullScreen ? "arrow.down.right.and.arrow.up.left":"arrow.up.left.and.arrow.down.right")}.help("Full screen · ⌃⌘F")
            if chromeMode != "normal" {Button {revealChrome=false;pinnedChrome=false} label:{Image(systemName:"chevron.up")}.help("Hide toolbar")}
        }.buttonStyle(.borderless).controlSize(.mini).font(.system(size:12))
            .foregroundStyle(activeTint).tint(activeTint)
            .padding(.leading,chromeMode=="normal" && !sidebarVisible && !model.isFullScreen ? 80:5).padding(.trailing,5).frame(height:30).background(DeckTheme.panel)
            .overlay(alignment:.bottom){activeTint.opacity(0.2).frame(height:1).allowsHitTesting(false)}
            .onHover {inside in
                hideTask?.cancel()
                if !inside && chromeMode != "normal" && !pinnedChrome {
                    hideTask=Task {try? await Task.sleep(nanoseconds:1_500_000_000);if !Task.isCancelled{withAnimation{revealChrome=false}}}
                }
            }
    }
    private func selectWorkspace(_ preset: WorkspacePreset) {
        model.saved.selectedWorkspace=preset.id;model.updateRenderingRates();model.persist();model.requestKeyboardFocus()
    }
    private var errorBanner: some View {
        HStack {Text(model.error).font(.caption).textSelection(.enabled);Spacer();Button{model.error=""}label:{Image(systemName:"xmark")}}.padding(6).background(.orange.opacity(0.12))
    }
}
