import Foundation
import Darwin

public enum LocalRPC {
    public static var directory: URL {
        if let path=ProcessInfo.processInfo.environment["DECK_STATE_DIR"],path.hasPrefix("/") { return URL(fileURLWithPath:path,isDirectory:true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DesktopDeck")
    }
    public static var socketPath: String { directory.appendingPathComponent("control.sock").path }
    public static let maxBytes = 24 * 1024 * 1024
    public static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw DeckError("Socket path too long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            path.utf8CString.withUnsafeBytes { bytes.copyBytes(from: $0) }
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }
    public static func connect() throws -> Int32 {
        var addr = try address(socketPath)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DeckError("Cannot create socket") }
        let result = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { Darwin.close(fd); throw DeckError("Desktop Deck is not running. Open the app first.") }
        guard configureStream(fd) else {Darwin.close(fd);throw DeckError("Cannot configure control socket")}
        return fd
    }
    public static func configureStream(_ fd: Int32) -> Bool {
        var timeout=timeval(tv_sec:35,tv_usec:0),one:Int32=1
        let length=socklen_t(MemoryLayout<timeval>.size)
        return setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,length)==0 && setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,length)==0 && setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,4)==0
    }
    public static func write(_ data: Data, fd: Int32) throws {
        let payload = data + Data([10]); var offset=0
        try payload.withUnsafeBytes { b in
            while offset < b.count {
                let n=Darwin.write(fd,b.baseAddress!.advanced(by:offset),b.count-offset)
                guard n > 0 else { throw DeckError("Connection closed while writing") }; offset += n
            }
        }
    }
    public static func read(fd: Int32) throws -> Data {
        var result=Data(); var buffer=[UInt8](repeating:0,count:65536)
        while result.count < maxBytes {
            let n=Darwin.read(fd,&buffer,min(buffer.count,maxBytes-result.count))
            guard n > 0 else { throw DeckError("Control connection closed or timed out") }
            if let newline=buffer[..<n].firstIndex(of:10) { result.append(contentsOf:buffer[..<newline]); return result }
            result.append(contentsOf:buffer[..<n])
        }
        throw DeckError("Control message exceeded size limit")
    }
    public static func request(_ request: [String:Any]) throws -> [String:Any] {
        let fd=try connect(); defer { Darwin.close(fd) }
        try write(JSONSerialization.data(withJSONObject:request),fd:fd)
        let result=try JSONSerialization.jsonObject(with:read(fd:fd)) as? [String:Any] ?? [:]
        if let error=result["error"] as? String { throw DeckError(error) }
        return result
    }
}
