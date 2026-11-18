import SwiftUI
import DeckCore

extension ActivityReading {
    var hint: String {
        switch source {
        case .desktop:
            let rate=ByteCountFormatter.string(fromByteCount:Int64(perSecond),countStyle:.file)
            return perSecond == 0 ? "VNC · no incoming data":"VNC · \(rate)/s received"
        case .terminal: return perSecond == 0 ? "SSH · no terminal output":"SSH · \(perSecond) output batches/s"
        }
    }
    var unit: String {if case .desktop=source {return "bytes/s"};return "batches/s"}
}

private struct ActivityBars: View {
    let reading: ActivityReading, tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(alignment:.bottom,spacing:2) {
            ForEach(0..<5) { index in
                RoundedRectangle(cornerRadius:0.75).fill(index < reading.segments ? tint:.white.opacity(0.36))
                    .frame(width:3,height:CGFloat(4+index*2))
            }
        }.shadow(color:.black.opacity(0.75),radius:1)
            .animation(reduceMotion ? nil:.easeOut(duration:0.16),value:reading.segments)
    }
}

struct ConnectionMark: View {
    let state: ConnectionIndicator, tint: Color
    var body: some View {
        Group {
            switch state {
            case .online: Circle().fill(tint).frame(width:6,height:6)
            case .offline: Circle().strokeBorder(.white.opacity(0.74),lineWidth:1.3).frame(width:7,height:7)
            case .connecting: Circle().trim(from:0.08,to:0.79).stroke(.yellow,style:StrokeStyle(lineWidth:1.5,lineCap:.round)).rotationEffect(.degrees(-90)).frame(width:7,height:7)
            case .attention: Image(systemName:"xmark").font(.system(size:8,weight:.bold)).foregroundStyle(.orange)
            }
        }.frame(width:9,height:9).accessibilityLabel(label)
    }
    private var label: String {
        switch state {case .online:return "Connected";case .offline:return "Disconnected";case .connecting:return "Connecting";case .attention:return "Needs attention"}
    }
}

struct TileChrome: View {
    @ObservedObject var session: DesktopSession
    let emphasized: Bool, open: ()->Void
    @Environment(\.displayScale) private var scale
    var body: some View {
        GeometryReader { geo in
            let size=geo.size
            let inset: CGFloat=size.width>=160 ? 7:4
            let footer=size.height>=48 && size.width>=44 && (session.activity != nil || session.showsMetricData)
            ZStack {
                VStack(spacing:0) {
                    LinearGradient(colors:[.black.opacity(0.82),.clear],startPoint:.top,endPoint:.bottom).frame(height:min(37,size.height*0.48))
                    Spacer(minLength:0)
                    if footer {LinearGradient(colors:[.clear,.black.opacity(0.8)],startPoint:.top,endPoint:.bottom).frame(height:min(28,size.height*0.44))}
                }.allowsHitTesting(false)
                VStack(alignment:.leading,spacing:0) {
                    HStack(spacing:5) {
                        ConnectionMark(state:session.indicator,tint:session.tint)
                        Text(session.profile.name).font(.system(size:12,weight:.semibold)).foregroundStyle(session.tint).lineLimit(1)
                        if !session.isOnline && size.width>=175 {
                            Text(session.connectionSummary).font(.system(size:10,weight:.medium)).foregroundStyle(.white.opacity(0.9)).lineLimit(1).truncationMode(.tail)
                        }
                    }.padding(inset).shadow(color:.black,radius:1,y:1).contentShape(Rectangle())
                        .onTapGesture(perform:open).onDrag{NSItemProvider(object:session.id.uuidString as NSString)}
                    Spacer(minLength:0)
                    if footer {
                        HStack(spacing:4) {
                            ViewThatFits(in:.horizontal) {HostMetricsReadout(session:session).fixedSize();Color.clear.frame(width:0,height:0)}
                            Spacer(minLength:0)
                            if let activity=session.activity {ActivityBars(reading:activity,tint:session.tint).fixedSize().layoutPriority(1)}
                        }.padding(.horizontal,inset).padding(.bottom,inset).allowsHitTesting(false)
                    }
                }.frame(maxWidth:.infinity,alignment:.leading)
                Rectangle().strokeBorder(borderColor,lineWidth:emphasized ? 2:1/max(1,scale)).allowsHitTesting(false)
            }.clipped()
        }
    }
    private var borderColor: Color {
        if emphasized {return session.tint}
        switch session.indicator {
        case .offline:return .white.opacity(0.28)
        case .attention:return .orange.opacity(0.75)
        case .connecting,.online:return session.tint.opacity(0.55)
        }
    }
}
