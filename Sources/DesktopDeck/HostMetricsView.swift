import SwiftUI
import DeckCore

extension HostMetrics {
    var rpc: [String:Any] {
        var data: [String:Any]=["os":platform.rawValue,"sampledAt":sampledAt.timeIntervalSince1970]
        if let cpuPercent {data["cpuPercent"]=cpuPercent}
        if let disk {data["diskAvailableBytes"]=disk.availableBytes;data["diskTotalBytes"]=disk.totalBytes;data["diskUsedPercent"]=disk.usedPercent;data["diskPath"]=disk.path}
        return data
    }
}
struct HostMetricsReadout: View {
    @ObservedObject var session: DesktopSession
    var sidebar=false
    @AppStorage("showHostMetrics") private var enabled=true
    private func percent(_ value: Double?) -> String {value.map{String(format:"%.0f%%",$0)} ?? "—"}
    private func bytes(_ value: UInt64) -> String {ByteCountFormatter.string(fromByteCount:Int64(clamping:value),countStyle:.file)}
    var body: some View {
        if enabled,session.profile.usesSSH,session.hostMetrics != nil || !session.hostMetricsError.isEmpty {
            TimelineView(.periodic(from:.now,by:30)) {context in
                let metrics=session.hostMetrics
                let stale=metrics.map{context.date.timeIntervalSince($0.sampledAt)>90} ?? true
                HStack(spacing:4) {
                    if sidebar {
                        Image(systemName:"cpu");Text(percent(metrics?.cpuPercent))
                        Image(systemName:"internaldrive");Text(metrics?.disk.map{bytes($0.availableBytes)} ?? "—")
                    } else {
                        Text("CPU \(percent(metrics?.cpuPercent)) · Disk \(percent(metrics?.disk?.usedPercent))")
                    }
                }.font(.system(size:9,weight:.medium,design:.monospaced)).lineLimit(1).fixedSize()
                    .foregroundStyle(sidebar ? Color.secondary:session.tint)
                    .opacity(stale ? 0.45:1).shadow(color:sidebar ? .clear:.black,radius:2,x:0,y:1)
                    .help(tooltip)
            }
        }
    }
    private var tooltip: String {
        var lines=[String]()
        if let metrics=session.hostMetrics {
            lines.append("Host CPU · \(metrics.platform.rawValue) · \(percent(metrics.cpuPercent))")
            if let disk=metrics.disk {lines.append("Disk \(disk.path) · \(bytes(disk.availableBytes)) available / \(bytes(disk.totalBytes)) total")}
            lines.append("Updated \(metrics.sampledAt.formatted(date:.omitted,time:.standard))")
        }
        if !session.hostMetricsError.isEmpty {lines.append(session.hostMetricsError)}
        return lines.joined(separator:"\n")
    }
}
