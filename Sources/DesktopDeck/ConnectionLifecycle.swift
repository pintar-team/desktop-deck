import Foundation
import DeckCore

@MainActor private final class ConnectionWaiter {
    enum Result {case closed(Bool,Bool),cancelled}
    let worker: VNCWorker
    private var result: Result?
    private var continuation: CheckedContinuation<Result,Never>?
    init(_ worker: VNCWorker) {self.worker=worker}
    func finish(_ result: Result) {
        guard self.result==nil else {return};self.result=result
        continuation?.resume(returning:result);continuation=nil
    }
    func wait() async -> Result {
        await withTaskCancellationHandler(operation:{
            await withCheckedContinuation {continuation in
                if let result {continuation.resume(returning:result)} else {self.continuation=continuation}
            }
        },onCancel:{Task {@MainActor in self.worker.stop();self.finish(.cancelled)}})
    }
}

@MainActor extension WorkspaceModel {
    func connectIfNeeded(_ session: DesktopSession) {
        if !session.isOnline && (!session.wantsConnection || session.needsAction) {connect(session)}
    }
    func disconnect(_ s: DesktopSession) {
        if !s.profile.hasVNC {s.terminals.forEach{$0.detach()}}
        s.cancelResolution();s.resetClipboard();s.desired=false;s.needsAction=false;s.generation += 1;s.task?.cancel();s.task=nil
        s.releaseInput();s.worker?.stop();s.worker=nil;s.tunnel?.stop();s.tunnel=nil
        s.phase = .disconnected;s.detail="";s.lastError="";s.retryAt=nil;s.lease=InputLease()
    }
    func connect(_ s: DesktopSession) {
        if !s.profile.hasVNC {
            if let tab=s.selectedTab,tab.profile.hasSameTerminalConnection(as:s.profile) {tab.detach();tab.connect()}
            else {_=openTerminal(s,present:false)}
            return
        }
        disconnect(s);s.desired=true;s.attemptNumber=0
        let generation=s.generation
        s.task=Task { [weak self,weak s] in
            guard let self,let s else {return}
            while s.desired && s.generation==generation && !Task.isCancelled {
                while !self.networkAvailable && !Task.isCancelled {
                    s.phase = .waitingNetwork;s.detail="Waiting for network; attempts are paused"
                    try? await Task.sleep(nanoseconds:250_000_000)
                }
                guard s.desired,s.generation==generation,!Task.isCancelled else {return}
                s.phase = .queued
                while self.connectingPermits>=2 && !Task.isCancelled {try? await Task.sleep(nanoseconds:100_000_000)}
                guard !Task.isCancelled,s.generation==generation else {return}
                self.connectingPermits += 1;var holdsPermit=true
                @MainActor func releasePermit() {if holdsPermit {self.connectingPermits -= 1;holdsPermit=false}}
                s.attemptNumber += 1;s.attemptSerial += 1;s.retryAt=nil;s.connectedAt=nil
                let serial=s.attemptSerial
                var timedOut=false
                var watchdog: Task<Void,Never>?
                let job=Task {try await self.establish(s,generation:generation,serial:serial,onReady:{releasePermit();watchdog?.cancel()})}
                watchdog=Task {
                    do {try await Task.sleep(nanoseconds:ConnectionLimits.attemptSeconds*1_000_000_000)} catch {return}
                    guard s.generation==generation,s.attemptSerial==serial,!s.active else {return}
                    timedOut=true;s.lastError="Timed out during \(s.phase.label.lowercased())"
                    job.cancel();s.worker?.stop();s.tunnel?.stop()
                }
                do {
                    try await withTaskCancellationHandler(operation:{try await job.value},onCancel:{job.cancel()})
                } catch {
                    watchdog?.cancel();releasePermit()
                    guard s.generation==generation,s.desired,!Task.isCancelled else {return}
                    s.worker?.stop();s.worker=nil;s.tunnel?.stop();s.tunnel=nil;s.releaseInput();s.resetClipboard();s.lease=InputLease()
                    let message=(timedOut ? s.lastError:error.localizedDescription).trimmingCharacters(in:.whitespacesAndNewlines)
                    s.lastError=message;s.detail=message
                    let lowered=message.lowercased()
                    if ["permission denied","host key verification","identification has changed","invalid connection","authentication rejected","pinned session missing"].contains(where:lowered.contains) {s.needsAction=true}
                    if s.needsAction {s.phase = .needsAttention;return}
                    if let connected=s.connectedAt,Date().timeIntervalSince(connected)>=ConnectionLimits.stableSeconds {s.attemptNumber=0}
                    if s.attemptNumber>=ConnectionLimits.attempts {
                        s.phase = .failed;s.needsAction=true;s.detail="Automatic retries exhausted";return
                    }
                    let delay=RetryPolicy.delay(attempt:max(0,s.attemptNumber-1),jitter:Double.random(in:0.8...1.2))
                    s.retryAt=Date().addingTimeInterval(delay);s.phase = .backoff
                    try? await Task.sleep(nanoseconds:UInt64(delay*1e9))
                }
            }
        }
    }
    private func establish(_ s: DesktopSession,generation: Int,serial: Int,onReady: @escaping @MainActor ()->Void) async throws {
        s.resetClipboard();let p=s.profile;try p.validate()
        var host=p.host,port=p.port,password=p.sessionManager ? "":Secrets.password(p)
        if p.sessionManager {
            s.phase = .listing;s.detail="Attempt \(s.attemptNumber) of \(ConnectionLimits.attempts)"
            s.remoteSessions=try await Commands.list(p);try Task.checkCancellation()
            guard s.remoteSessions.contains(where:{$0.display==p.display}) else {throw DeckError("Pinned session missing. Select or create a session.")}
            s.phase = .authorizing
            port=5900+(try RemoteSession.displayNumber(p.display));password=try await Commands.otp(p)
        }
        try Task.checkCancellation()
        if p.usesSSH {
            s.phase = .tunneling
            let tunnel=try SSHTunnel(profile:p,remotePort:port);s.tunnel=tunnel
            try await tunnel.waitReady();host="127.0.0.1";port=tunnel.port
        }
        try Task.checkCancellation()
        guard s.generation==generation else {throw CancellationError()}
        s.phase = .handshake
        let worker=VNCWorker(),waiter: ConnectionWaiter
        waiter=ConnectionWaiter(worker);s.worker=worker;s.connectionRevision += 1
        func current() -> Bool {s.generation==generation && s.attemptSerial==serial && s.desired}
        worker.onConnected = {guard current() else {return};s.phase = .synchronizing;s.quality();self.updateRenderingRates()}
        worker.onFrame = {frame in
            guard current() else {return}
            if !s.active {s.connectedAt=Date();onReady()}
            s.phase = .connected;s.detail=""
            if let pending=s.pendingResolution,pending.0==frame.width,pending.1==frame.height {s.pendingResolution=nil;s.resolutionStatus="\(frame.width) × \(frame.height) · applied"}
            if s.frame?.width != frame.width || s.frame?.height != frame.height {s.geometry += 1;s.releaseInput()}
            let delta=frame.time.timeIntervalSince(s.lastFrameTime)
            if s.profile.quality=="auto",Date().timeIntervalSince(s.qualityChanged)>5,delta>0,delta<2 {
                let q=delta>0.35 ? max(3,s.adaptiveQuality-1):delta<0.08 ? min(9,s.adaptiveQuality+1):s.adaptiveQuality
                if q != s.adaptiveQuality {s.adaptiveQuality=q;s.qualityChanged=Date();s.quality()}
            }
            s.lastFrameTime=frame.time;s.frame=frame
        }
        worker.onClosed = {established,auth in waiter.finish(.closed(established,auth))}
        worker.onResizeResult = {result in
            guard current() else {return}
            if result<0 {s.pendingResolution=nil;s.resolutionStatus=result == -1 ? "Server has not advertised desktop resizing support":"Invalid resolution"}
        }
        worker.onClipboard = {text in guard current() else {return};s.receiveClipboard(text)}
        worker.onClipboardSent = {result in guard current() else {return};s.clipboardSent(result)}
        defer {worker.onConnected=nil;worker.onFrame=nil;worker.onClosed=nil;worker.onResizeResult=nil;worker.onClipboard=nil;worker.onClipboardSent=nil}
        worker.start(host:host,port:port,password:password,sshOTP:p.sessionManager && p.usesSSH)
        let result=await waiter.wait()
        try Task.checkCancellation()
        switch result {
        case .cancelled:throw CancellationError()
        case .closed(_,true):throw DeckError("VNC authentication rejected. Check password and server security type.")
        case .closed(let established,false):throw DeckError(established ? "Connection interrupted":"VNC handshake interrupted")
        }
    }
}
