import SwiftUI
import DeckCore

struct WorkspacePresetEditor: View {
    @ObservedObject var model: WorkspaceModel
    @State private var name=""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Workspace").font(.title2)
            TextField("Name",text:$name).textFieldStyle(.roundedBorder)
            Text("Connections · drag to reorder").font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(model.workspace.profiles,id:\.self){id in
                    if let s=model.sessions.first(where:{$0.id==id}) {Toggle(s.profile.name,isOn:Binding(get:{true},set:{_ in model.updateWorkspace{$0.profiles.removeAll{$0==id}}}))}
                }.onMove{source,target in model.updateWorkspace{$0.profiles.move(fromOffsets:source,toOffset:target)}}
                ForEach(model.sessions.filter{!model.workspace.profiles.contains($0.id)}){s in
                    Toggle(s.profile.name,isOn:Binding(get:{false},set:{_ in model.updateWorkspace{$0.profiles.append(s.id)}}))
                }
            }.frame(height:260)
            HStack {
                if model.saved.workspaces.count>1 {Button("Delete workspace",role:.destructive){let id=model.workspace.id;model.saved.workspaces.removeAll{$0.id==id};model.saved.selectedWorkspace=model.saved.workspaces[0].id;model.persist();dismiss()}}
                Spacer();Button("Done"){model.updateWorkspace{$0.name=name.isEmpty ? "Workspace":name};dismiss()}.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width:420).onAppear{name=model.workspace.name}
    }
}
