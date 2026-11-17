import Foundation
import AppKit
import UniformTypeIdentifiers
import DeckCore

@MainActor extension WorkspaceModel {
    func configurationArchive() -> ConnectionArchive {
        var workspaces=saved.workspaces
        for i in workspaces.indices {workspaces[i].normalize()}
        return ConnectionArchive(profiles:sessions.map(\.profile),workspaces:workspaces)
    }
    func importConfiguration(_ archive: ConnectionArchive) throws -> [String:Int] {
        try archive.validate()
        let wasEmpty=sessions.isEmpty
        let oldProfiles=Set(sessions.map(\.id)),oldWorkspaces=Set(saved.workspaces.map(\.id))
        let added=archive.profiles.filter{!oldProfiles.contains($0.id)}
        for p in added {let s=DesktopSession(p);sessions.append(s);assignColor(s);observe(s)}
        let workspaces=archive.workspaces.filter{!oldWorkspaces.contains($0.id)}
        if wasEmpty && !archive.workspaces.isEmpty {saved.workspaces=archive.workspaces;saved.selectedWorkspace=archive.workspaces.first?.id}
        else {saved.workspaces.append(contentsOf:workspaces)}
        if archive.workspaces.isEmpty {saved.workspaces[workspaceIndex].profiles.append(contentsOf:added.map(\.id));saved.workspaces[workspaceIndex].normalize()}
        persist()
        return ["addedProfiles":added.count,"addedWorkspaces":workspaces.count,"existingProfiles":archive.profiles.count-added.count,"existingWorkspaces":archive.workspaces.count-workspaces.count]
    }
    func exportConfiguration() {
        let panel=NSSavePanel();panel.allowedContentTypes=[.json];panel.nameFieldStringValue="Desktop Deck.json"
        panel.begin {response in
            guard response == .OK,let url=panel.url else {return}
            do {let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];try encoder.encode(self.configurationArchive()).write(to:url,options:.atomic)}
            catch {self.error=error.localizedDescription}
        }
    }
    func importConfigurationFile() {
        let panel=NSOpenPanel();panel.allowedContentTypes=[.json];panel.allowsMultipleSelection=false
        panel.begin {response in
            guard response == .OK,let url=panel.url else {return}
            do {
                let attributes=try FileManager.default.attributesOfItem(atPath:url.path)
                guard ((attributes[.size] as? NSNumber)?.intValue ?? 0)<=4_000_000 else {throw DeckError("Configuration file exceeds 4 MB")}
                let result=try self.importConfiguration(JSONDecoder().decode(ConnectionArchive.self,from:Data(contentsOf:url)))
                self.focused?.showFeedback("Imported \(result["addedProfiles"] ?? 0) connections")
            } catch {self.error=error.localizedDescription}
        }
    }
    func manageProfiles(_ arguments: [String:Any]) throws -> [String:Any] {
        let action=arguments["action"] as? String ?? ""
        func object(_ p: Profile) throws -> [String:Any] {try JSONSerialization.jsonObject(with:JSONEncoder().encode(p)) as! [String:Any]}
        if action=="list" {return ["profiles":try sessions.map{try object($0.profile)}]}
        let id=(arguments["profile"] as? String).flatMap(UUID.init(uuidString:))
        let existing=id.flatMap{id in sessions.first{$0.id==id}}
        if action=="remove" {guard let existing else {throw DeckError("Unknown profile ID")};delete(existing);return ["removed":true]}
        if action=="get" {guard let existing else {throw DeckError("Unknown profile ID")};return ["configuration":try object(existing.profile)]}
        guard ["add","update","duplicate"].contains(action) else {throw DeckError("Expected list, get, add, update or duplicate")}
        var profile: Profile
        if action=="add" {profile=Profile()}
        else {
            guard let existing else {throw DeckError("Unknown profile ID")};profile=existing.profile
            if action=="duplicate" {profile=profile.duplicated()}
        }
        let previous=profile
        var data=try object(profile)
        let allowed=Set(["name","group","host","port","sshHost","sshUser","sshPort","hostKeyAlias","sessionManager","display","autoConnect","terminalMode","quality","serverDirectory","surfaceMode","tintHex"])
        if let patch=arguments["configuration"] as? [String:Any] {
            guard Set(patch.keys).isSubset(of:allowed) else {throw DeckError("Unknown or immutable configuration field")}
            for (key,value) in patch {data[key]=value}
        }
        profile=try JSONDecoder().decode(Profile.self,from:JSONSerialization.data(withJSONObject:data))
        profile.clearInheritedHostKeyAlias(from:previous,explicitlySet:(arguments["configuration"] as? [String:Any])?["hostKeyAlias"] != nil)
        if profile.name.isEmpty || profile.name=="New connection" {profile.name=profile.usesSSH ? profile.sshHost:profile.host}
        if !profile.hasVNC {profile.surfaceMode="terminal"}
        let password=arguments["password"] as? String
        guard (password?.utf8.count ?? 0)<=1024 else {throw DeckError("Password is too long")}
        try add(profile,password:password)
        return ["id":profile.id.uuidString,"configuration":try object(profile)]
    }
    func transferConfiguration(_ arguments: [String:Any]) throws -> [String:Any] {
        switch arguments["action"] as? String {
        case "export":return ["configuration":try JSONSerialization.jsonObject(with:JSONEncoder().encode(configurationArchive()))]
        case "import":
            guard let data=arguments["configuration"] as? [String:Any] else {throw DeckError("Expected configuration object")}
            let encoded=try JSONSerialization.data(withJSONObject:data)
            guard encoded.count<=4_000_000 else {throw DeckError("Configuration exceeds 4 MB")}
            let result=try importConfiguration(JSONDecoder().decode(ConnectionArchive.self,from:encoded))
            return result.mapValues{$0 as Any}
        default:throw DeckError("Expected import or export")
        }
    }
}
