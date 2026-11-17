import Foundation
import Security
import CryptoKit
import DeckCore
struct SavedState: Codable {
    var profiles=[Profile]()
    var workspaces=[WorkspacePreset(name:"All desktops",profiles:[])]
    var selectedWorkspace: UUID?
    var terminals: [SavedTerminal]?
}
struct SavedTerminal: Codable { let id: UUID; let profile: UUID; let reconnect: Bool;var profileSnapshot: Profile? }
enum Storage {
    static var stateURL: URL { LocalRPC.directory.appendingPathComponent("workspace.json") }
    static func load() throws -> SavedState {
        guard FileManager.default.fileExists(atPath:stateURL.path) else { return SavedState() }
        return try JSONDecoder().decode(SavedState.self,from:Data(contentsOf:stateURL))
    }
    static func save(_ state: SavedState) throws {
        try FileManager.default.createDirectory(at:LocalRPC.directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let encoder=JSONEncoder(); encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(state).write(to:stateURL,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:stateURL.path)
    }
}
enum Secrets {
    private static func binding(_ p: Profile) -> Data {
        let target=[p.host,String(p.port),p.sshHost,p.sshUser,String(p.sshPort),p.hostKeyAlias]
        return Data(SHA256.hash(data:(try? JSONEncoder().encode(target)) ?? Data()))
    }
    private static func query(_ id: UUID) -> [String:Any] {
        [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"DesktopDeck.VNC",kSecAttrAccount as String:id.uuidString]
    }
    static func bindLegacy(_ profile: Profile) {
        guard profile.hasVNC,!profile.sessionManager else {return}
        var item: CFTypeRef?,q=query(profile.id);q[kSecReturnAttributes as String]=true
        guard SecItemCopyMatching(q as CFDictionary,&item)==errSecSuccess,let attributes=item as? [String:Any],attributes[kSecAttrGeneric as String]==nil else {return}
        _=SecItemUpdate(query(profile.id) as CFDictionary,[kSecAttrGeneric as String:binding(profile)] as CFDictionary)
    }
    static func password(_ profile: Profile) -> String {
        var item: CFTypeRef?
        var q=query(profile.id);q[kSecReturnData as String]=true;q[kSecReturnAttributes as String]=true
        guard SecItemCopyMatching(q as CFDictionary,&item)==errSecSuccess,let attributes=item as? [String:Any],
              attributes[kSecAttrGeneric as String] as? Data==binding(profile),let data=attributes[kSecValueData as String] as? Data else { return "" }
        return String(decoding:data,as:UTF8.self)
    }
    static func set(_ value: String,profile: Profile) throws {
        let q=query(profile.id)
        if value.isEmpty { SecItemDelete(q as CFDictionary); return }
        let attrs=[kSecValueData as String:Data(value.utf8),kSecAttrGeneric as String:binding(profile)]
        var status=SecItemUpdate(q as CFDictionary,attrs as CFDictionary)
        if status==errSecItemNotFound { status=SecItemAdd(q.merging(attrs){_,new in new} as CFDictionary,nil) }
        guard status==errSecSuccess else { throw DeckError("Keychain write failed (\(status))") }
    }
}
