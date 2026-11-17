import Foundation

public struct WorkspacePreset: Codable,Identifiable {
    public var id: UUID
    public var name: String
    public var profiles: [UUID]
    public var focused: UUID?
    public var focusMode=false
    public var tileWidth: Double=420
    public var gridMode: Int?
    public init(name: String,profiles: [UUID],id: UUID=UUID()) {self.id=id;self.name=name;self.profiles=profiles}
    public mutating func normalize() {
        var seen=Set<UUID>();profiles=profiles.filter{seen.insert($0).inserted}
        if focused==nil || !profiles.contains(focused!) {focused=profiles.first}
    }
}
public struct ConnectionArchive: Codable {
    public var version=1
    public var profiles: [Profile]
    public var workspaces: [WorkspacePreset]
    public init(profiles: [Profile],workspaces: [WorkspacePreset]) {self.profiles=profiles;self.workspaces=workspaces}
    public func validate() throws {
        guard version==1 else {throw DeckError("Unsupported configuration version")}
        guard profiles.count<=1000,workspaces.count<=200 else {throw DeckError("Configuration is too large")}
        let ids=Set(profiles.map(\.id))
        guard ids.count==profiles.count,Set(workspaces.map(\.id)).count==workspaces.count else {throw DeckError("Duplicate IDs in configuration")}
        for p in profiles {try p.validate()}
        for w in workspaces {
            guard Set(w.profiles).count==w.profiles.count,w.profiles.allSatisfy({ids.contains($0)}),
                  w.focused==nil || w.profiles.contains(w.focused!) else {throw DeckError("Invalid workspace connection references")}
        }
    }
}
