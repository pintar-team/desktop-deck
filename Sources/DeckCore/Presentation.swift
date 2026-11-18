import Foundation

public enum SplitLayout {
    public static let dividerHeight=7.0, tabBarHeight=24.0
    public static func terminalHeight(preferred: Double, available: Double) -> Double {
        let space=max(0,available-dividerHeight-tabBarHeight)
        let minimum=min(120,space/2)
        return min(space-minimum,max(minimum,preferred))
    }
}

public enum ViewMode: String,CaseIterable,Identifiable {
    case overview,desktop,terminal,split
    public var id: String {rawValue}
    public var title: String {
        switch self {case .overview:return "Overview";case .desktop:return "Desktop";case .terminal:return "Terminal";case .split:return "Split"}
    }
    public var symbol: String {
        switch self {case .overview:return "square.grid.2x2";case .desktop:return "display";case .terminal:return "terminal";case .split:return "rectangle.split.1x2"}
    }
    public var showsDesktop: Bool {self == .desktop || self == .split}
    public var showsTerminal: Bool {self == .terminal || self == .split}
}
public enum ConnectionIndicator: Equatable {case online,offline,connecting,attention}

public enum ConnectionPhase: String {
    case disconnected,queued,waitingNetwork,listing,authorizing,tunneling,handshake,synchronizing,connected,backoff,failed,needsAttention
    public var indicator: ConnectionIndicator {
        switch self {
        case .connected:return .online
        case .disconnected:return .offline
        case .failed,.needsAttention:return .attention
        case .queued,.waitingNetwork,.listing,.authorizing,.tunneling,.handshake,.synchronizing,.backoff:return .connecting
        }
    }
    public var label: String {
        switch self {
        case .disconnected:return "Disconnected"
        case .queued:return "Queued"
        case .waitingNetwork:return "Offline"
        case .listing:return "Finding desktop"
        case .authorizing:return "Requesting access"
        case .tunneling:return "Opening SSH tunnel"
        case .handshake:return "VNC handshake"
        case .synchronizing:return "Receiving first frame"
        case .connected:return "Connected"
        case .backoff:return "Reconnecting"
        case .failed:return "Connection failed"
        case .needsAttention:return "Needs attention"
        }
    }
}
public enum ConnectionLimits {
    public static let attempts=6
    public static let attemptSeconds: UInt64=30
    public static let stableSeconds: TimeInterval=30
}
public struct CopyFeedbackIntent {
    private var expires: Date?
    public init() {}
    public mutating func request(now: Date=Date()) {expires=now.addingTimeInterval(2)}
    public mutating func consume(now: Date=Date()) -> Bool {
        defer {expires=nil}
        return expires.map{now<$0} ?? false
    }
}
