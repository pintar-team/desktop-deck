import SwiftUI

struct ResolutionControl: View {
    @ObservedObject var session: DesktopSession
    @State private var show=false
    @State private var width=1920
    @State private var height=1080
    var body: some View {
        Button {width=session.frame?.width ?? 1920;height=session.frame?.height ?? 1080;show.toggle()} label:{
            Text("\(session.frame?.width ?? 0) × \(session.frame?.height ?? 0)").font(.system(size:11,design:.monospaced))
        }.help("Actual remote resolution; click to change").popover(isPresented:$show) {
            VStack(alignment:.leading,spacing:12) {
                Text("Remote resolution").font(.headline)
                HStack {TextField("Width",value:$width,format:.number.grouping(.never));Text("×");TextField("Height",value:$height,format:.number.grouping(.never))}.textFieldStyle(.roundedBorder)
                HStack {ForEach([(1280,800),(1920,1080),(2560,1440)],id:\.0) {w,h in Button("\(w) × \(h)"){width=w;height=h} }}.controlSize(.small)
                if !session.resolutionStatus.isEmpty {Text(session.resolutionStatus).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
                HStack {Spacer();Button("Apply") {do{try session.requestResolution(width:width,height:height)}catch{session.resolutionStatus=error.localizedDescription}}.buttonStyle(.borderedProminent)}
            }.padding(16).frame(width:320)
        }
    }
}
