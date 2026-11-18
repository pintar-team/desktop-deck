import Foundation
import DeckCore

struct HostEndpoint: Hashable {
    let host: String,alias: String
    let port: Int
    init(_ p: Profile) {host=p.sshHost;alias=p.hostKeyAlias;port=p.sshPort}
}
enum HostMetricsProbe {
    static let interval: TimeInterval=30
    static let disk="LC_ALL=C df -kP / | awk 'NR==2 {printf \"DISK_KIB\\t%.0f\\t%.0f\\t/\\n\", $2, $4}'"
    static let windowsScript="""
    $ErrorActionPreference='Stop'
    if ([Environment]::OSVersion.Platform -ne 'Win32NT') { exit 1 }
    Write-Output 'DECK_WINDOWS'
    try {
      $cpu=Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -OperationTimeoutSec 3
      if ($null -ne $cpu) { Write-Output ("CPU_PERCENT`t" + $cpu.PercentProcessorTime) }
    } catch {}
    try {
      $drive=$env:SystemDrive
      $disk=Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$drive'" -OperationTimeoutSec 3
      if ($disk.Size -gt 0) { Write-Output ("DISK_BYTES`t"+$disk.Size+"`t"+$disk.FreeSpace+"`t"+$drive+'\\') }
    } catch {}
    """
    static var windowsCommand: String {
        "powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand "+windowsScript.data(using:.utf16LittleEndian)!.base64EncodedString()
    }
    static func command(_ platform: HostPlatform) -> String {
        let cpu: String
        switch platform {
        case .linux:
            // Linux guest ticks are already included in user/nice. Idle includes iowait.
            cpu="LC_ALL=C awk '/^cpu / {t=0; for(i=2;i<=9 && i<=NF;i++) t+=$i; printf \"CPU_COUNTER\\t%.0f\\t%.0f\\n\",t,$5+$6; exit}' /proc/stat"
        case .macOS:
            cpu="LC_ALL=C top -l 2 -n 0 -s 1 | awk '/CPU usage:/ {v=$0; sub(/^.*,[[:space:]]*/,\"\",v); sub(/%.*/,\"\",v); cpu=100-v; seen=1} END {if(seen && cpu>=0 && cpu<=100) printf \"CPU_PERCENT\\t%.2f\\n\",cpu}'"
        case .bsd:
            cpu="sysctl -n kern.cp_time | awk 'NF>=5 {t=0; for(i=1;i<=NF;i++)t+=$i; printf \"CPU_COUNTER\\t%.0f\\t%.0f\\n\",t,$NF}'"
        case .windows:return windowsCommand
        case .unix:return disk
        }
        return cpu+"; "+disk
    }
    static func detect(_ p: Profile) async throws -> HostPlatform {
        if let output=try? await Commands.ssh(p,"uname -s",timeout:8),let platform=HostPlatform.detect(uname:output) {return platform}
        try Task.checkCancellation()
        let output=try await Commands.ssh(p,windowsCommand,timeout:8)
        guard output.split(whereSeparator:\.isNewline).contains("DECK_WINDOWS") else {throw DeckError("SSH host metrics are unavailable")}
        return .windows
    }
    static func read(_ p: Profile,platform: HostPlatform) async throws -> RawHostMetrics {
        let output=try await Commands.ssh(p,command(platform),timeout:8)
        guard let raw=RawHostMetrics.parse(output) else {throw DeckError("CPU and disk metrics are unavailable")}
        return raw
    }
}
@MainActor final class HostMonitor {
    private final class Entry {
        var platform: HostPlatform?
        var accumulator=HostMetricsAccumulator()
        var metrics: HostMetrics?
        var error=""
        var due=Date.distantPast
        var failures=0
    }
    private var entries=[HostEndpoint:Entry]()
    private var job: Task<Void,Never>?
    private var running: HostEndpoint?
    private let update: (HostEndpoint,HostMetrics?,String)->Void
    init(update: @escaping (HostEndpoint,HostMetrics?,String)->Void) {self.update=update}
    func tick(_ sessions: [DesktopSession],enabled: Bool) {
        guard enabled else {job?.cancel();return}
        let configured=Set(sessions.filter{ $0.profile.usesSSH }.map{HostEndpoint($0.profile)})
        entries=entries.filter{configured.contains($0.key)}
        if let running,!configured.contains(running) {job?.cancel()}
        for key in configured {
            if let entry=entries[key] {update(key,entry.metrics,entry.error)}
        }
        guard job==nil else {return}
        var candidates=[HostEndpoint:Profile]()
        for s in sessions where s.profile.usesSSH {
            let key=HostEndpoint(s.profile)
            let terminalOnline=s.terminals.contains{$0.isOnline && HostEndpoint($0.profile)==key}
            if (s.isOnline || terminalOnline),candidates[key]==nil {candidates[key]=s.profile}
        }
        let now=Date()
        guard let key=candidates.keys.filter({(entries[$0]?.due ?? .distantPast)<=now}).min(by:{(entries[$0]?.due ?? .distantPast)<(entries[$1]?.due ?? .distantPast)}),let p=candidates[key] else {return}
        let entry=entries[key] ?? Entry();entries[key]=entry;running=key
        job=Task {[weak self] in
            guard let self else {return}
            defer {self.job=nil;self.running=nil}
            do {
                let platform: HostPlatform
                if let cached=entry.platform {platform=cached} else {platform=try await HostMetricsProbe.detect(p);entry.platform=platform}
                if let old=entry.metrics,Date().timeIntervalSince(old.sampledAt)>HostMetricsProbe.interval*1.5 {entry.accumulator=HostMetricsAccumulator()}
                var raw=try await HostMetricsProbe.read(p,platform:platform)
                var metrics=entry.accumulator.record(raw,platform:platform)
                if raw.counters != nil && metrics.cpuPercent==nil {
                    try await Task.sleep(nanoseconds:1_000_000_000)
                    raw=try await HostMetricsProbe.read(p,platform:platform);metrics=entry.accumulator.record(raw,platform:platform)
                }
                try Task.checkCancellation()
                guard self.entries[key] === entry else {return}
                entry.metrics=metrics;entry.error="";entry.failures=0;entry.due=Date().addingTimeInterval(HostMetricsProbe.interval)
            } catch {
                guard !Task.isCancelled else {return}
                entry.error="Host metrics unavailable";entry.failures += 1
                if entry.failures>=3 {entry.platform=nil}
                entry.due=Date().addingTimeInterval(min(120,HostMetricsProbe.interval*Double(min(4,entry.failures))))
            }
            self.update(key,entry.metrics,entry.error)
        }
    }
    func stop() {job?.cancel()}
}
