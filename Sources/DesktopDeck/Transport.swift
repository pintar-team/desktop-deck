import Foundation
import DeckCore
import Darwin

struct CommandResult { let output: String; let status: Int32 }
enum Commands {
    static func serverTool(_ p: Profile,_ name: String) -> String {Shell.quote(p.turboVNCDirectory+"/bin/"+name)}
    static func run(_ executable: String, _ arguments: [String], timeout: Double = 20) async throws -> CommandResult {
        let job=Task.detached { () throws -> CommandResult in
            let task=Process(), pipe=Pipe(); task.executableURL=URL(fileURLWithPath:executable)
            task.arguments=arguments; task.standardInput=FileHandle.nullDevice
            task.standardOutput=pipe; task.standardError=pipe
            let capture=Capture()
            let fd=pipe.fileHandleForReading.fileDescriptor
            guard fcntl(fd,F_SETFL,fcntl(fd,F_GETFL)|O_NONBLOCK)==0 else {throw DeckError("Cannot configure command output")}
            try task.run()
            try? pipe.fileHandleForWriting.close()
            defer {stopOwned(task);try? pipe.fileHandleForReading.close()}
            let end=Date().addingTimeInterval(timeout)
            while task.isRunning {
                try Task.checkCancellation()
                drain(fd,into:capture)
                guard Date()<end else {throw DeckError("SSH command exceeded \(Int(timeout)) seconds")}
                try await Task.sleep(nanoseconds:30_000_000)
            }
            drain(fd,into:capture)
            return CommandResult(output:capture.text,status:task.terminationStatus)
        }
        return try await withTaskCancellationHandler(operation:{try await job.value},onCancel:{job.cancel()})
    }
    private static func drain(_ fd: Int32,into capture: Capture) {
        var buffer=[UInt8](repeating:0,count:8192)
        for _ in 0..<16 {
            let count=Darwin.read(fd,&buffer,buffer.count)
            if count<=0 {return};capture.append(Data(buffer.prefix(count)))
        }
    }
    private static func stopOwned(_ task: Process) {
        guard task.isRunning else {return};task.terminate()
        let deadline=Date().addingTimeInterval(0.2)
        while task.isRunning && Date()<deadline {usleep(10_000)}
        if task.isRunning {kill(task.processIdentifier,SIGKILL)}
    }
    static func ssh(_ p: Profile, _ command: String, timeout: Double = 20) async throws -> String {
        let r=try await run("/usr/bin/ssh",Shell.sshArguments(p)+["--",Shell.destination(p),command],timeout:timeout)
        guard r.status == 0 else { throw DeckError(r.output.trimmingCharacters(in:.whitespacesAndNewlines).prefix(800).description) }
        return r.output
    }
    static func list(_ p: Profile) async throws -> [RemoteSession] {
        try RemoteSession.parse(await ssh(p,"\(serverTool(p,"vncserver")) -sessionlist"))
    }
    static func otp(_ p: Profile) async throws -> String {
        _ = try RemoteSession.displayNumber(p.display)
        let output=try await ssh(p,"\(serverTool(p,"vncpasswd")) -o -display \(Shell.quote(p.display))")
        for line in output.split(separator:"\n").reversed() {
            let s=line.trimmingCharacters(in:.whitespacesAndNewlines)
            if s.count == 8 && !s.contains(" ") { return s }
            if let range=s.range(of:"password:",options:.caseInsensitive) {
                let value=s[range.upperBound...].trimmingCharacters(in:.whitespacesAndNewlines)
                if value.count == 8 { return value }
            }
        }
        throw DeckError("Server did not return a TurboVNC OTP")
    }
}
final class Capture: @unchecked Sendable {
    private let lock=NSLock(); private var bytes=Data()
    func append(_ data: Data) { lock.lock(); defer { lock.unlock() }; bytes.append(data); if bytes.count>131072 { bytes.removeFirst(bytes.count-131072) } }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding:bytes,as:UTF8.self) }
}

final class SSHTunnel {
    let process=Process(); let capture=Capture(); private let pipe=Pipe()
    let port: Int
    init(profile: Profile, remotePort: Int) throws {
        let fd=socket(AF_INET,SOCK_STREAM,0); guard fd >= 0 else { throw DeckError("Cannot allocate local tunnel") }
        var addr=sockaddr_in(); addr.sin_family=sa_family_t(AF_INET); addr.sin_addr.s_addr=inet_addr("127.0.0.1")
        let bound=withUnsafePointer(to:&addr) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound==0 else { close(fd); throw DeckError("Cannot bind local tunnel") }
        var length=socklen_t(MemoryLayout<sockaddr_in>.size)
        _=withUnsafeMutablePointer(to:&addr) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { getsockname(fd,$0,&length) } }
        port=Int(UInt16(bigEndian:addr.sin_port)); close(fd)
        process.executableURL=URL(fileURLWithPath:"/usr/bin/ssh")
        process.arguments=Shell.sshArguments(profile)+["-o","ExitOnForwardFailure=yes","-N","-L",
            "127.0.0.1:\(port):\(profile.sessionManager ? "127.0.0.1" : profile.host):\(remotePort)","--",profile.sshHost]
        process.standardInput=FileHandle.nullDevice; process.standardError=pipe; process.standardOutput=FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [capture] in capture.append($0.availableData) }
        try process.run()
    }
    func waitReady() async throws {
        let end=Date().addingTimeInterval(10)
        while process.isRunning && Date()<end {
            try Task.checkCancellation()
            let fd=socket(AF_INET,SOCK_STREAM,0)
            var a=sockaddr_in(); a.sin_family=sa_family_t(AF_INET); a.sin_port=UInt16(port).bigEndian; a.sin_addr.s_addr=inet_addr("127.0.0.1")
            let ok=withUnsafePointer(to:&a) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }; close(fd)
            if ok==0 { return }
            try await Task.sleep(nanoseconds:50_000_000)
        }
        throw DeckError(capture.text.isEmpty ? "SSH tunnel did not become ready" : capture.text)
    }
    func stop() { pipe.fileHandleForReading.readabilityHandler=nil; if process.isRunning { process.terminate() } }
    deinit { stop() }
}
