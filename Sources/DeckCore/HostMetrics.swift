import Foundation

public enum HostPlatform: String,Sendable {
    case linux="Linux",macOS="macOS",bsd="BSD",windows="Windows",unix="Unix"
    public static func detect(uname: String) -> Self? {
        guard let name=uname.split(whereSeparator:\.isNewline).last?.trimmingCharacters(in:.whitespacesAndNewlines) else {return nil}
        switch name {
        case "Linux":return .linux
        case "Darwin":return .macOS
        case "FreeBSD","OpenBSD","NetBSD","DragonFly":return .bsd
        case "SunOS","AIX","GNU":return .unix
        default:return name.hasPrefix("CYGWIN") || name.hasPrefix("MSYS") || name.hasPrefix("MINGW") ? .unix:nil
        }
    }
}
public struct CPUCounters: Equatable,Sendable {
    public let total: UInt64,idle: UInt64
}
public struct HostDisk: Equatable,Sendable {
    public let totalBytes: UInt64,availableBytes: UInt64
    public let path: String
    public var usedPercent: Double {100*(1-Double(availableBytes)/Double(totalBytes))}
}
public struct RawHostMetrics: Sendable {
    public var counters: CPUCounters?
    public var cpuPercent: Double?
    public var disk: HostDisk?
    public static func parse(_ output: String) -> Self? {
        var value=Self()
        for line in output.split(whereSeparator:\.isNewline) {
            let fields=line.split(separator:"\t",omittingEmptySubsequences:false).map(String.init)
            switch fields.first {
            case "CPU_COUNTER":
                if fields.count==3,let total=UInt64(fields[1]),let idle=UInt64(fields[2]),total>0,idle<=total {value.counters=CPUCounters(total:total,idle:idle)}
            case "CPU_PERCENT":
                if fields.count==2,let percent=Double(fields[1]),percent.isFinite,(0...100).contains(percent) {value.cpuPercent=percent}
            case "DISK_KIB","DISK_BYTES":
                guard fields.count==4,let total=UInt64(fields[1]),let available=UInt64(fields[2]),total>0,available<=total else {continue}
                let scale: UInt64=fields[0]=="DISK_KIB" ? 1024:1
                let (bytes,overflow)=total.multipliedReportingOverflow(by:scale)
                guard !overflow else {continue}
                value.disk=HostDisk(totalBytes:bytes,availableBytes:available*scale,path:fields[3])
            default:continue
            }
        }
        return value.counters != nil || value.cpuPercent != nil || value.disk != nil ? value:nil
    }
}
public struct HostMetrics: Equatable,Sendable {
    public let platform: HostPlatform
    public let cpuPercent: Double?
    public let disk: HostDisk?
    public let sampledAt: Date
}
public struct HostMetricsAccumulator: Sendable {
    private var previous: CPUCounters?
    public init() {}
    public mutating func record(_ raw: RawHostMetrics,platform: HostPlatform,at date: Date=Date()) -> HostMetrics {
        var cpu=raw.cpuPercent
        if let current=raw.counters {
            if let previous,current.total>previous.total,current.idle>=previous.idle {
                let total=current.total-previous.total,idle=current.idle-previous.idle
                if idle<=total {cpu=100*(1-Double(idle)/Double(total))}
            }
            previous=current
        } else {previous=nil}
        return HostMetrics(platform:platform,cpuPercent:cpu,disk:raw.disk,sampledAt:date)
    }
}
