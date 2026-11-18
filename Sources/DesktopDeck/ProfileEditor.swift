import SwiftUI
import DeckCore

struct ProfileDraft: Identifiable {
    var profile: Profile
    var duplicateSource: UUID?
    var id: UUID {profile.id}
}
struct ProfileEditor: View {
    @ObservedObject var model: WorkspaceModel
    @State var profile: Profile
    var duplicateSource: UUID?
    @State private var password=""
    @State private var clearPassword=false
    @State private var error=""
    @Environment(\.dismiss) private var dismiss
    private var tint: Color {DeckTheme.color(profile.tintHex ?? profile.autoTintHex ?? DeckTheme.palette[0].hex)}
    private var existing: Bool {model.sessions.contains{$0.id==profile.id}}
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack(spacing:8) {
                Text(duplicateSource==nil ? "Connection":"Duplicate connection").font(.system(size:18,weight:.semibold))
                Spacer()
                capability("terminal","SSH",profile.usesSSH)
                capability("display","VNC",profile.hasVNC)
            }
            HStack(spacing:8) {
                TextField("Name",text:$profile.name)
                TextField("Group",text:$profile.group).frame(width:115)
            }
            section("SSH",icon:"terminal",active:profile.usesSSH) {
                HStack(spacing:8) {TextField("Host or SSH alias",text:$profile.sshHost);portField($profile.sshPort)}
                TextField("User",text:$profile.sshUser)
                DisclosureGroup("Advanced") {
                    VStack(spacing:8) {
                        TextField("Host-key alias",text:$profile.hostKeyAlias)
                        Picker("Terminal",selection:$profile.terminalMode){Text("Auto").tag("auto");Text("Plain SSH").tag("plain")}
                    }.padding(.top,6)
                }.font(.system(size:11)).foregroundStyle(.secondary)
            }
            section("VNC",icon:"display",active:profile.hasVNC) {
                Picker("VNC mode",selection:$profile.sessionManager){Text("Direct").tag(false);Text("Session Manager").tag(true)}
                    .labelsHidden().pickerStyle(.segmented)
                if profile.sessionManager {
                    TextField("Screen · :1",text:$profile.display)
                } else {
                    HStack(spacing:8) {TextField("Host",text:$profile.host);portField($profile.port)}
                    SecureField(existing ? "Password · unchanged":"Password",text:$password)
                }
                if profile.sessionManager || existing {
                    DisclosureGroup("Advanced") {
                        if profile.sessionManager {
                            TextField("TurboVNC directory",text:Binding(get:{profile.turboVNCDirectory},set:{profile.serverDirectory=$0.isEmpty ? nil:$0})).padding(.top,6)
                        } else {Toggle("Clear saved password",isOn:$clearPassword).padding(.top,6)}
                    }.font(.system(size:11)).foregroundStyle(.secondary)
                }
            }
            HStack(spacing:8) {
                Toggle("Auto-connect",isOn:$profile.autoConnect).toggleStyle(.switch).controlSize(.mini)
                Spacer()
                Menu {
                    Button("Automatic"){profile.tintHex=nil}
                    Divider()
                    ForEach(DeckTheme.palette,id:\.hex){color in Button(color.name){profile.tintHex=color.hex}}
                } label:{Label("Color",systemImage:"circle.fill").foregroundStyle(tint)}.fixedSize()
                if profile.tintHex != nil {ColorPicker("Custom color",selection:Binding(get:{tint},set:{profile.tintHex=DeckTheme.hex($0)}),supportsOpacity:false).labelsHidden().frame(width:26)}
            }.font(.system(size:11))
            if !error.isEmpty {Text(error).foregroundStyle(.orange).font(.caption)}
            HStack {Spacer();Button("Cancel"){dismiss()}.keyboardShortcut(.cancelAction);Button("Save",action:save).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!profile.usesSSH && !profile.hasVNC)}
        }.textFieldStyle(.roundedBorder).controlSize(.small).padding(20).frame(width:440).background(DeckTheme.panel).tint(tint)
            .onChange(of:profile.sshServerAddress){_,_ in profile.hostKeyAlias=""}
    }
    private func section<Content: View>(_ title: String,icon: String,active: Bool,@ViewBuilder content: ()->Content) -> some View {
        VStack(alignment:.leading,spacing:8) {
            Label(title,systemImage:icon).font(.system(size:12,weight:.semibold)).foregroundStyle(active ? tint:.secondary)
            content()
        }.padding(12).background(DeckTheme.background.opacity(0.6),in:RoundedRectangle(cornerRadius:7))
            .overlay(RoundedRectangle(cornerRadius:7).strokeBorder(active ? tint.opacity(0.45):DeckTheme.border.opacity(0.4),lineWidth:1).allowsHitTesting(false))
    }
    private func capability(_ icon: String,_ title: String,_ active: Bool) -> some View {
        Label(title,systemImage:icon).font(.system(size:10,weight:.medium)).foregroundStyle(active ? tint:.secondary.opacity(0.4))
    }
    private func portField(_ value: Binding<Int>) -> some View {
        TextField("Port",value:value,format:.number.grouping(.never)).frame(width:65).help("Port")
    }
    private func save() {
        profile.name=profile.name.trimmingCharacters(in:.whitespacesAndNewlines)
        profile.host=profile.host.trimmingCharacters(in:.whitespacesAndNewlines)
        profile.sshHost=profile.sshHost.trimmingCharacters(in:.whitespacesAndNewlines)
        profile.sshUser=profile.sshUser.trimmingCharacters(in:.whitespacesAndNewlines)
        if profile.name.isEmpty || profile.name=="New connection" {profile.name=profile.usesSSH ? profile.sshHost:profile.host}
        if !profile.hasVNC {profile.surfaceMode="terminal"}
        if profile.sessionManager && profile.display.isEmpty {error="Select a screen";return}
        if profile.sessionManager && !profile.usesSSH {error="SSH host is required";return}
        var secret: String?=nil
        if !profile.sessionManager && profile.hasVNC {
            if clearPassword {secret=""}
            else if !password.isEmpty {secret=password}
        }
        do {try model.add(profile,password:secret);dismiss()} catch {self.error=error.localizedDescription}
    }
}
