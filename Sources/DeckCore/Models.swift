import Foundation

public struct Profile: Codable, Identifiable, Equatable {
    public static let defaultTurboVNCDirectory="/opt/TurboVNC"
    public var id: UUID
    public var name: String
    public var group: String
    public var host: String
    public var port: Int
    public var sshUser: String
    public var sshHost: String
    public var sshPort: Int
    public var hostKeyAlias: String
    public var sessionManager: Bool
    public var display: String
    public var autoConnect: Bool
    public var terminalMode: String
    public var quality: String
    public var serverDirectory: String?
    public var surfaceMode: String?
    public var tintHex: String?
    public var autoTintHex: String?
    public init(name: String = "New connection", host: String = "", port: Int = 5900,
                sshUser: String = "", sshHost: String = "", hostKeyAlias: String = "",
                sessionManager: Bool = false, display: String = "") {
        id = UUID(); self.name = name; group = ""; self.host = host; self.port = port
        self.sshUser = sshUser; self.sshHost = sshHost; sshPort = 22
        self.hostKeyAlias = hostKeyAlias; self.sessionManager = sessionManager
        self.display = display; autoConnect = false; terminalMode = "auto"; quality = "auto"
        serverDirectory=nil
        surfaceMode=nil
        tintHex=nil;autoTintHex=nil
    }
    public var usesSSH: Bool { !sshHost.isEmpty }
    public var turboVNCDirectory: String {
        let directory=serverDirectory?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        return directory.isEmpty ? Self.defaultTurboVNCDirectory:directory
    }
    public var hasVNC: Bool {!host.isEmpty || sessionManager}
    public func duplicated() -> Profile {
        var copy=self;copy.id=UUID();copy.name += " copy";copy.autoConnect=false;copy.tintHex=nil;copy.autoTintHex=nil
        return copy
    }
    public var sshServerAddress: [String] {[sshHost,String(sshPort)]}
    public mutating func clearInheritedHostKeyAlias(from previous: Profile,explicitlySet: Bool=false) {
        if !explicitlySet,sshServerAddress != previous.sshServerAddress,hostKeyAlias==previous.hostKeyAlias {hostKeyAlias=""}
    }
    public func hasSameSSHConnection(as other: Profile) -> Bool {
        guard usesSSH==other.usesSSH else {return false}
        return !usesSSH || (sshServerAddress==other.sshServerAddress && sshUser==other.sshUser && hostKeyAlias==other.hostKeyAlias)
    }
    public func hasSameTerminalConnection(as other: Profile) -> Bool {hasSameSSHConnection(as:other) && terminalMode==other.terminalMode}
    public func hasSameVNCConnection(as other: Profile) -> Bool {
        guard hasVNC==other.hasVNC else {return false}
        guard hasVNC else {return true}
        return host==other.host && port==other.port && sessionManager==other.sessionManager && hasSameSSHConnection(as:other)
            && (!sessionManager || (display==other.display && turboVNCDirectory==other.turboVNCDirectory))
    }
    public func supports(_ mode: ViewMode) -> Bool {
        (!mode.showsDesktop || hasVNC) && (!mode.showsTerminal || usesSSH)
    }
    public func validate() throws {
        guard !name.isEmpty, hasVNC || usesSSH, (!hasVNC || sessionManager || (1...65535).contains(port)),
              (!usesSSH || (1...65535).contains(sshPort)), !host.hasPrefix("-"),
              !sshHost.hasPrefix("-"), !sshUser.hasPrefix("-"),
              !sessionManager || usesSSH else { throw DeckError("Invalid connection settings") }
        if sessionManager && !display.isEmpty { _ = try RemoteSession.displayNumber(display) }
    }
}

public enum ConnectionOrder {
    public static func reorder(_ current: [UUID],using order: [UUID]) -> [UUID] {
        let existing=Set(current);var seen=Set<UUID>()
        let replacement=order.filter{existing.contains($0) && seen.insert($0).inserted}
        let moving=Set(replacement);var next=replacement.makeIterator()
        return current.map{moving.contains($0) ? (next.next() ?? $0):$0}
    }
}
public struct RemoteSession: Equatable, Codable {
    public let display: String
    public let pid: Int
    public let socket: String?
    public static func displayNumber(_ value: String) throws -> Int {
        guard value.hasPrefix(":"), let n = Int(value.dropFirst()), (1...65535-5900).contains(n)
        else { throw DeckError("Invalid display; expected :1, :2, …") }
        return n
    }
    public static func parse(_ text: String) throws -> [RemoteSession] {
        // SSH login banners are ignored; accept only the complete machine-readable row.
        for line in text.split(separator: "\n").reversed() {
            let f = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard f.count >= 2, let count = Int(f[0]), let stride = Int(f[1]),
                  (0...1000).contains(count), (5...64).contains(stride), f.count == 2 + count * stride else { continue }
            return try (0..<count).map { index in
                let offset = 2 + index * stride
                _ = try displayNumber(f[offset])
                guard let pid = Int(f[offset+1]), pid > 0 else { throw DeckError("Invalid session PID") }
                return RemoteSession(display: f[offset], pid: pid, socket: f[offset+3] == "@NONE" ? nil : f[offset+3])
            }
        }
        throw DeckError("Server returned an unsupported session list")
    }
}

public struct DeckError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum Shell {
    public static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    public static func sshArguments(_ p: Profile, interactive: Bool = false) -> [String] {
        var result = ["-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=8",
                      "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2",
                      "-o", "BatchMode=yes", "-p", String(p.sshPort)]
        if !p.hostKeyAlias.isEmpty { result += ["-o", "HostKeyAlias=\(p.hostKeyAlias)"] }
        if !p.sshUser.isEmpty { result += ["-l", p.sshUser] }
        if interactive { result += ["-tt"] }
        return result
    }
    public static func destination(_ p: Profile) -> String { p.sshHost }
}

public struct RetryPolicy {
    public static func delay(attempt: Int, jitter: Double) -> TimeInterval {
        let schedule: [Double] = [1,2,4,8,15,30]
        return schedule[min(max(attempt, 0), schedule.count-1)] * min(1.2, max(0.8, jitter))
    }
    public static func mayRetry(desired: Bool, current: Bool, inFlight: Bool, needsAction: Bool) -> Bool {
        desired && current && !inFlight && !needsAction
    }
}

public struct InputLease {
    public private(set) var owner: String?
    public private(set) var expiry = Date.distantPast
    public private(set) var humanUntil = Date.distantPast
    public init() {}
    public mutating func human(now: Date = Date()) { owner = nil; expiry = .distantPast; humanUntil = now.addingTimeInterval(2) }
    public mutating func acquire(_ client: String, now: Date = Date()) throws {
        guard now >= humanUntil, owner == nil || owner == client || now >= expiry else { throw DeckError("INPUT_BUSY: human or another MCP client has control") }
        owner = client; expiry = now.addingTimeInterval(10)
    }
    public func validate(_ client: String, generation: Int, expectedGeneration: Int,
                         geometry: Int, expectedGeometry: Int, connected: Bool, now: Date = Date()) throws {
        guard connected, generation == expectedGeneration, geometry == expectedGeometry else { throw DeckError("STALE_SESSION: refresh screenshot or terminal state") }
        guard owner == client, now < expiry, now >= humanUntil else { throw DeckError("INPUT_BUSY") }
    }
}

public struct ViewTransform {
    public let width: Double, height: Double, frameWidth: Double, frameHeight: Double
    public let zoom: Double, panX: Double, panY: Double
    public init(width: Double, height: Double, frameWidth: Double, frameHeight: Double,
                zoom: Double = 1, panX: Double = 0, panY: Double = 0) {
        self.width=width; self.height=height; self.frameWidth=frameWidth; self.frameHeight=frameHeight
        self.zoom=zoom; self.panX=panX; self.panY=panY
    }
    public var scale: Double { min(width/max(frameWidth,1), height/max(frameHeight,1)) * zoom }
    public var origin: (Double,Double) { ((width-frameWidth*scale)/2+panX, (height-frameHeight*scale)/2+panY) }
    public func remote(x: Double, y: Double) -> (Int,Int)? {
        let o=origin, rx=(x-o.0)/scale, ry=(y-o.1)/scale
        guard rx >= 0, ry >= 0, rx < frameWidth, ry < frameHeight else { return nil }
        return (Int(rx), Int(ry))
    }
}
