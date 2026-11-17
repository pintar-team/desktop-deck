import AppKit
import ImageIO
import DeckCore

enum ImageClipboard {
    static let limit=20_000_000
    static let clipboardInputLimit=168_000_000
    static func read(_ board: NSPasteboard) throws -> Data? {
        if let data=board.data(forType:.png) {return try bounded(data)}
        if let data=board.data(forType:.tiff) {return try bounded(data,limit:clipboardInputLimit)}
        let files=board.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL] ?? []
        let supported=Set(["png","jpg","jpeg","webp","gif","heic","heif","tif","tiff","bmp"])
        guard let file=files.first,supported.contains(file.pathExtension.lowercased()) else {return nil}
        guard files.count==1 else {throw DeckError("Drop one image at a time")}
        return try readFile(file)
    }
    static func readFile(_ file: URL) throws -> Data {
        let access=file.startAccessingSecurityScopedResource();defer {if access {file.stopAccessingSecurityScopedResource()}}
        let properties=try file.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey])
        guard properties.isRegularFile==true,(properties.fileSize ?? 0)<=limit else {throw DeckError("Choose an image file smaller than 20 MB")}
        let handle=try FileHandle(forReadingFrom:file);defer {try? handle.close()}
        return try bounded(handle.read(upToCount:limit+1) ?? Data())
    }
    private static func bounded(_ data: Data,limit: Int=ImageClipboard.limit) throws -> Data {
        guard !data.isEmpty else {throw DeckError("Image is empty")}
        guard data.count<=limit else {throw DeckError(limit==Self.limit ? "PNG must be smaller than 20 MB":"Clipboard image is too large")};return data
    }
    static func png(_ data: Data) throws -> Data {
        _=try bounded(data,limit:clipboardInputLimit)
        guard let source=CGImageSourceCreateWithData(data as CFData,nil),
              let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let w=properties[kCGImagePropertyPixelWidth] as? NSNumber,let h=properties[kCGImagePropertyPixelHeight] as? NSNumber else {throw DeckError("Unsupported image")}
        let width=w.doubleValue,height=h.doubleValue
        guard width>0,height>0,width<=16384,height<=16384,width*height<=40_000_000 else {throw DeckError("Image dimensions are too large")}
        let options:[CFString:Any]=[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:Int(max(width,height)),kCGImageSourceShouldCacheImmediately:true]
        guard let image=CGImageSourceCreateThumbnailAtIndex(source,0,options as CFDictionary) else {throw DeckError("Cannot decode image")}
        let output=NSMutableData()
        guard let destination=CGImageDestinationCreateWithData(output,"public.png" as CFString,1,nil) else {throw DeckError("Cannot encode image")}
        CGImageDestinationAddImage(destination,image,nil)
        guard CGImageDestinationFinalize(destination) else {throw DeckError("Cannot encode image")}
        return try bounded(output as Data)
    }
    static func command(_ profile: Profile,token: String) throws -> String {
        guard profile.usesSSH,!profile.display.isEmpty else {throw DeckError("Image paste needs SSH and a selected X11 screen")}
        guard profile.sessionManager || ["localhost","127.0.0.1","::1"].contains(profile.host) else {throw DeckError("Image paste needs SSH on the desktop host")}
        _=try RemoteSession.displayNumber(profile.display)
        let script="""
        set -eu
        [ "$(uname -s)" = Linux ] || { echo DECK_IMAGE_UNSUPPORTED; exit 1; }
        command -v xclip >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1 || { echo DECK_IMAGE_NEEDS_XCLIP; exit 1; }
        export DISPLAY=\(Shell.quote(profile.display))
        umask 077
        directory=$(mktemp -d "${TMPDIR:-/tmp}/desktop-deck-image.XXXXXXXX")
        pid=''
        cleanup() {
          if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
          rm -f -- "$directory/image.png"
          rmdir -- "$directory"
        }
        trap cleanup EXIT
        trap 'exit 1' HUP INT TERM
        timeout -k 1 15 cat > "$directory/image.png"
        timeout -k 1 30 xclip -quiet -selection clipboard -target image/png -in "$directory/image.png" >/dev/null 2>&1 &
        pid=$!
        ready=0
        attempt=0
        while [ "$attempt" -lt 6 ]; do
          if timeout -k 1 2 xclip -selection clipboard -target image/png -out 2>/dev/null | cmp -s "$directory/image.png" -; then ready=1; break; fi
          kill -0 "$pid" 2>/dev/null || break
          attempt=$((attempt+1))
          sleep 0.1
        done
        [ "$ready" = 1 ] || { echo DECK_IMAGE_NO_DISPLAY; exit 1; }
        printf '%s\\n' \(Shell.quote("DECK_IMAGE_READY_"+token))
        wait "$pid" || true
        pid=''
        """
        return "sh -c "+Shell.quote(script)
    }
}

@MainActor final class PromisedImageDrop {
    private let directory=FileManager.default.temporaryDirectory.appendingPathComponent("desktop-deck-drop-"+UUID().uuidString,isDirectory:true)
    private let receiver: NSFilePromiseReceiver
    private var completion: ((Data?,String?)->Void)?
    private var deadline: Task<Void,Never>?
    init(_ receiver: NSFilePromiseReceiver,completion: @escaping (Data?,String?)->Void) throws {
        guard receiver.fileNames.count==1 else {throw DeckError("Drop one image at a time")}
        self.receiver=receiver;self.completion=completion
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        receiver.receivePromisedFiles(atDestination:directory,options:[:],operationQueue:.main) {[weak self] file,error in
            Task {@MainActor in
                guard let self else {return}
                guard self.completion != nil else {try? FileManager.default.removeItem(at:self.directory);return}
                do {
                    if let error {throw error}
                    guard file.resolvingSymlinksInPath().deletingLastPathComponent()==self.directory.resolvingSymlinksInPath() else {throw DeckError("Invalid promised image location")}
                    self.finish(try ImageClipboard.readFile(file),error:nil)
                }
                catch {self.finish(nil,error:error.localizedDescription)}
            }
        }
        deadline=Task {[weak self] in
            try? await Task.sleep(for:.seconds(30));guard !Task.isCancelled else {return}
            self?.finish(nil,error:"Image drop timed out")
        }
    }
    private func finish(_ data: Data?,error: String?) {
        let callback=completion;completion=nil;deadline?.cancel()
        try? FileManager.default.removeItem(at:directory);callback?(data,error)
    }
    func cancel() {completion=nil;deadline?.cancel();try? FileManager.default.removeItem(at:directory)}
    deinit {deadline?.cancel();try? FileManager.default.removeItem(at:directory)}
}

actor ImageEncoder {
    static let shared=ImageEncoder()
    private var busy=false
    func png(_ data: Data) async throws -> Data {
        guard !busy else {throw DeckError("Image conversion is still in progress")}
        busy=true;defer{busy=false}
        let job=Task.detached(priority:.userInitiated){try Task.checkCancellation();return try ImageClipboard.png(data)}
        return try await withTaskCancellationHandler(operation:{try await job.value},onCancel:{job.cancel()})
    }
}

@MainActor extension DesktopSession {
    func cancelImageTransfer() {imageTransferID=nil;imageTransfer?.cancel();imageTransfer=nil;imageUploading=false}
    func pasteImage(_ data: Data,keys: [UInt32]?=[0xffe3,0x76]) {
        do {
            guard active else {throw DeckError("Desktop is not connected")}
            guard !clipboardInFlight else {throw DeckError("Clipboard transfer is still in progress")}
            let id=UUID(),snapshot=profile,revision=connectionRevision,geometry=geometry
            let command=try ImageClipboard.command(profile,token:id.uuidString),marker="DECK_IMAGE_READY_"+id.uuidString
            cancelImageTransfer();humanInput();releaseInput()
            let humanRevision=humanActionRevision
            inputView?.window?.makeFirstResponder(inputView)
            imageTransferID=id;imageUploading=true;showFeedback("Sending image…")
            imageTransfer=Task {[weak self] in
                let directory=FileManager.default.temporaryDirectory.appendingPathComponent("desktop-deck-image-"+id.uuidString,isDirectory:true)
                defer {try? FileManager.default.removeItem(at:directory)}
                do {
                    let png=try await ImageEncoder.shared.png(data)
                    try Task.checkCancellation()
                    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
                    let file=directory.appendingPathComponent("image.png");try png.write(to:file)
                    try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
                    let result=try await Commands.run("/usr/bin/ssh",Shell.sshArguments(snapshot)+["--",Shell.destination(snapshot),command],timeout:45,inputFile:file) {output in
                        if output.split(whereSeparator:\.isNewline).contains(Substring(marker)) {
                            Task {@MainActor [weak self] in self?.imageReady(id,revision:revision,geometry:geometry,humanRevision:humanRevision,keys:keys)}
                        }
                    }
                    try Task.checkCancellation()
                    guard let self,self.imageTransferID==id else {return}
                    if result.status != 0 {
                        let message=result.output.contains("DECK_IMAGE_NEEDS_XCLIP") ? "Image paste requires xclip and timeout on the SSH host":result.output.contains("DECK_IMAGE_UNSUPPORTED") ? "Image paste currently supports Linux X11 over SSH":"Cannot access the selected screen's image clipboard"
                        throw DeckError(message)
                    }
                    self.imageTransferID=nil;self.imageTransfer=nil;self.imageUploading=false
                } catch {
                    guard let self,self.imageTransferID==id else {return}
                    self.imageTransferID=nil;self.imageTransfer=nil;self.imageUploading=false
                    if !Task.isCancelled {self.showFeedback(error.localizedDescription)}
                }
            }
        } catch {showFeedback(error.localizedDescription)}
    }
    private func imageReady(_ id: UUID,revision: Int,geometry: Int,humanRevision: Int,keys: [UInt32]?) {
        guard imageTransferID==id,imageUploading else {return};imageUploading=false
        guard active,connectionRevision==revision,self.geometry==geometry else {showFeedback("Screen changed — image paste cancelled");cancelImageTransfer();return}
        guard let keys else {showFeedback("Image clipboard ready");return}
        guard humanActionRevision==humanRevision,lease.owner==nil,let inputView,inputView.session?.id==self.id,let window=inputView.window,window.isKeyWindow,NSApp.isActive,window.firstResponder === inputView else {showFeedback("Image ready — paste in the remote app");return}
        humanInput(invalidatePendingPaste:false);releaseInput()
        if sendChord(keys) {showFeedback("Image paste sent")}
    }
}
