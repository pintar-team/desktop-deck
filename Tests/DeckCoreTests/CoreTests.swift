import XCTest
@testable import DeckCore

final class CoreTests: XCTestCase {
    func testArchiveRoundtripAndInvalidReferences() throws {
        let a=Profile(host:"localhost"),b=Profile(host:"",sshHost:"localhost")
        var w=WorkspacePreset(name:"Test",profiles:[b.id,a.id]);w.focused=b.id;w.gridMode=3
        let archive=ConnectionArchive(profiles:[a,b],workspaces:[w]);try archive.validate()
        let data=try JSONEncoder().encode(archive)
        XCTAssertFalse(String(decoding:data,as:UTF8.self).contains("password"))
        let restored=try JSONDecoder().decode(ConnectionArchive.self,from:data)
        XCTAssertEqual(restored.workspaces[0].profiles,[b.id,a.id]);XCTAssertEqual(restored.workspaces[0].gridMode,3)
        var invalid=archive;invalid.workspaces[0].profiles.append(UUID());XCTAssertThrowsError(try invalid.validate())
        invalid=archive;invalid.version=999;XCTAssertThrowsError(try invalid.validate())
        invalid=archive;invalid.profiles.append(a);XCTAssertThrowsError(try invalid.validate())
    }
    func testEndpointCapabilitiesAndModes() throws {
        XCTAssertThrowsError(try Profile().validate())
        var ssh=Profile(host:"",sshHost:"localhost");ssh.port=0
        XCTAssertNoThrow(try ssh.validate());XCTAssertFalse(ssh.hasVNC)
        XCTAssertTrue(ssh.supports(.terminal));XCTAssertFalse(ssh.supports(.desktop));XCTAssertFalse(ssh.supports(.split))
        var vnc=Profile(host:"localhost");vnc.sshPort=0
        XCTAssertNoThrow(try vnc.validate());XCTAssertTrue(vnc.supports(.desktop));XCTAssertFalse(vnc.supports(.terminal))
        var managed=ssh;managed.sessionManager=true
        XCTAssertTrue(managed.supports(.split));XCTAssertNoThrow(try managed.validate())
        managed.sshHost="";XCTAssertThrowsError(try managed.validate())
    }
    func testReorderingFilteredConnectionsPreservesHiddenPositions() {
        let a=UUID(),b=UUID(),c=UUID(),d=UUID()
        XCTAssertEqual(ConnectionOrder.reorder([a,b,c,d],using:[c,a]),[c,b,a,d])
        XCTAssertEqual(ConnectionOrder.reorder([a,b,c,d],using:[c,c,a,UUID()]),[c,b,a,d])
    }
    func testCopyFeedbackIgnoresSelectionChangesAndExpiresAcrossDelayedUpdates() {
        var intent=CopyFeedbackIntent();let now=Date()
        XCTAssertFalse(intent.consume(now:now),"Selection changes alone must not say Copied")
        intent.request(now:now)
        XCTAssertTrue(intent.consume(now:now.addingTimeInterval(0.1)))
        XCTAssertFalse(intent.consume(now:now.addingTimeInterval(0.2)),"One copy must not label subsequent primary selections")
        intent.request(now:now)
        XCTAssertFalse(intent.consume(now:now.addingTimeInterval(3)),"Delayed unrelated clipboard data must not confirm a copy")
    }
    func testSessionListAndForwardCompatibleFields() throws {
        let list=try RemoteSession.parse("banner\n2\t6\t:11\t12345\t0\t@NONE\t0\textra\t:12\t67890\t0\t/tmp/owned.sock\t0\textra\n")
        XCTAssertEqual(list.map(\.display),[":11",":12"])
        XCTAssertNil(list[0].socket); XCTAssertEqual(list[1].socket,"/tmp/owned.sock")
        XCTAssertEqual(try RemoteSession.parse("0 5"),[])
    }
    func testMalformedSessionListDoesNotSelectAnotherDesktop() {
        for input in ["1 5 :1 12", "1 5 :bad 12 0 @NONE 0", "1 5 :1 -1 0 @NONE 0", "1000000000 5"] {
            XCTAssertThrowsError(try RemoteSession.parse(input))
        }
    }
    func testShellQuotingPreservesQuotesAndSubstitution() {
        XCTAssertEqual(Shell.quote("a'$(touch /bad)"),"'a'\\''$(touch /bad)'")
        var p=Profile(host:"localhost",sshUser:"-bad",sshHost:"localhost")
        XCTAssertThrowsError(try p.validate()); p.sshUser="good"; XCTAssertNoThrow(try p.validate())
    }
    func testProfileBackwardCompatibilityForNewPresentationSettings() throws {
        var profile=Profile(host:"localhost")
        profile.tintHex="7AC8FF";profile.surfaceMode="terminal"
        let encoder=JSONEncoder(),decoder=JSONDecoder()
        let encoded=try encoder.encode(profile)
        XCTAssertEqual(try decoder.decode(Profile.self,from:encoded).tintHex,"7AC8FF")
        var legacy=try JSONSerialization.jsonObject(with:encoded) as! [String:Any]
        for key in ["tintHex","autoTintHex","surfaceMode","serverDirectory"] {legacy.removeValue(forKey:key)}
        let restored=try decoder.decode(Profile.self,from:JSONSerialization.data(withJSONObject:legacy))
        XCTAssertNil(restored.tintHex);XCTAssertNil(restored.surfaceMode)
    }
    func testReconnectInvariantsExhaustively() {
        for desired in [false,true] { for current in [false,true] { for flight in [false,true] { for action in [false,true] {
            let allowed=RetryPolicy.mayRetry(desired:desired,current:current,inFlight:flight,needsAction:action)
            if allowed { XCTAssertTrue(desired && current && !flight && !action) }
        } } } }
        XCTAssertEqual(RetryPolicy.delay(attempt:100,jitter:1),30)
    }
    func testHumanPrecedenceAndGenerationGuards() throws {
        var lease=InputLease(); let now=Date()
        try lease.acquire("agent",now:now)
        XCTAssertNoThrow(try lease.validate("agent",generation:1,expectedGeneration:1,geometry:2,expectedGeometry:2,connected:true,now:now))
        XCTAssertThrowsError(try lease.validate("agent",generation:2,expectedGeneration:1,geometry:2,expectedGeometry:2,connected:true,now:now))
        XCTAssertThrowsError(try lease.validate("agent",generation:1,expectedGeneration:1,geometry:3,expectedGeometry:2,connected:true,now:now))
        XCTAssertThrowsError(try lease.acquire("other",now:now))
        lease.human(now:now)
        XCTAssertThrowsError(try lease.acquire("agent",now:now.addingTimeInterval(1)))
        XCTAssertNoThrow(try lease.acquire("agent",now:now.addingTimeInterval(3)))
    }
    func testLetterboxingAndZoomCoordinateMapping() {
        let fit=ViewTransform(width:1000,height:1000,frameWidth:2000,frameHeight:1000)
        XCTAssertNil(fit.remote(x:10,y:100))
        XCTAssertEqual(fit.remote(x:500,y:500)?.0,1000)
        XCTAssertEqual(fit.remote(x:500,y:500)?.1,500)
        let zoom=ViewTransform(width:1000,height:1000,frameWidth:2000,frameHeight:1000,zoom:2,panX:100)
        XCTAssertEqual(zoom.remote(x:600,y:500)?.0,1000)
    }
    func testToolSchemasRequireGenerationForInput() {
        for name in ["screen_input","terminal_input"] {
            let tool=ToolDefinitions.all.first{$0.name==name}!
            XCTAssertTrue((tool.schema["required"] as! [String]).contains("generation"))
        }
        XCTAssertEqual(Set(ToolDefinitions.all.map(\.name)).count,ToolDefinitions.all.count)
    }
    func testCompactGridContainsEveryConnectionWithFixedColumns() {
        for count in 1...50 {
            let auto=GridLayout(count:count,width:1200,height:750)
            XCTAssertGreaterThanOrEqual(auto.capacity,count)
        }
        let fixed=GridLayout(count:17,width:1200,height:750,fixed:4)
        XCTAssertEqual(fixed.columns,4); XCTAssertEqual(fixed.rows,5); XCTAssertGreaterThanOrEqual(fixed.capacity,17)
        let six=GridLayout(count:6,width:1200,height:750)
        XCTAssertEqual(six.columns,3); XCTAssertEqual(six.rows,2)
    }
}
