import Foundation
import CVNC

struct Frame {
    let pixels: Data
    let width: Int, height: Int
    let sequence: Int
    let time: Date
}
final class VNCWorker: @unchecked Sendable {
    enum Event { case pointer(Int,Int,Int), key(UInt32,Bool), quality(Int,Int), resize(Int,Int), refresh, cancelResize, clipboard(String) }
    private let lock=NSLock()
    private var cancelled=false, events=[Event](), pendingFrame=false,pendingClipboard=false
    private var interval: Double=0.1
    private var handle: OpaquePointer?
    var onFrame: ((Frame)->Void)?
    var onConnected: (()->Void)?
    var onClosed: ((Bool,Bool)->Void)?
    var onResizeResult: ((Int)->Void)?
    var onClipboard: ((String)->Void)?
    var onClipboardSent: ((Int)->Void)?
    var receivedBytes: UInt64? {
        lock.lock(); defer { lock.unlock() }
        var total: UInt64=0
        guard let handle, !cancelled, deck_vnc_received_bytes(handle,&total) != 0 else {return nil}
        return total
    }
    func enqueue(_ event: Event) {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return }
        if case .pointer(_,_,let mask)=event,let previous=events.last,case .pointer(_,_,let prior)=previous,mask==prior {
            events[events.count-1]=event; return
        }
        guard events.count<16384 else { cancelled=true; events.removeAll(); return }; events.append(event)
    }
    func enqueueBatch(_ commands: [Event]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled,events.count+commands.count<=16384 else { return false }; events.append(contentsOf:commands); return true
    }
    func setFPS(_ fps: Double) { lock.lock(); interval=1/max(fps,1); lock.unlock() }
    func stop() { lock.lock(); cancelled=true; events.removeAll(); if let handle {deck_vnc_interrupt(handle)};lock.unlock() }
    private func take() -> (Bool,[Event],Double,Bool,Bool) {
        lock.lock(); defer { lock.unlock() }; let result=(cancelled,events,interval,pendingFrame,pendingClipboard); events.removeAll(keepingCapacity:true); return result
    }
    func start(host: String,port: Int,password: String,sshOTP: Bool=false) {
        Thread.detachNewThread { [self] in
            guard let client=deck_vnc_create() else { return }
            lock.lock();handle=client;let alreadyCancelled=cancelled;lock.unlock()
            if alreadyCancelled {deck_vnc_interrupt(client)}
            defer {lock.lock();handle=nil;deck_vnc_free(client);lock.unlock()}
            let ok=deck_vnc_connect(client,host,Int32(port),password,sshOTP ? 1:0) != 0
            if !ok { let auth=deck_vnc_auth_failed(client) != 0; DispatchQueue.main.async { self.onClosed?(false,auth) }; return }
            DispatchQueue.main.async { self.onConnected?() }
            var last=Date.distantPast,lastDecoded=Date.distantPast,sequence=0,dirty=false,valid=true
            while valid {
                let (stop,commands,interval,pending,clipboardPending)=take(); if stop { break }
                for event in commands {
                    let sent: Int32
                    switch event {
                    case .pointer(let x,let y,let mask): sent=deck_vnc_pointer(client,Int32(x),Int32(y),Int32(mask))
                    case .key(let key,let down): sent=deck_vnc_key(client,key,down ? 1:0)
                    case .quality(let q,let c): sent=deck_vnc_quality(client,Int32(q),Int32(c))
                    case .resize(let w,let h):
                        let result=deck_vnc_resize(client,Int32(w),Int32(h))
                        DispatchQueue.main.async {self.onResizeResult?(Int(result))}
                        sent=result<0 ? 1:result
                    case .refresh: sent=deck_vnc_refresh(client)
                    case .cancelResize: sent=deck_vnc_cancel_resize(client)
                    case .clipboard(let text):
                        let legacy=text.data(using:.isoLatin1)
                        let result=text.withCString {utf8 in
                            if let legacy {return legacy.withUnsafeBytes {deck_vnc_send_clipboard(client,utf8,Int32(text.utf8.count),$0.baseAddress,Int32(legacy.count))}}
                            return deck_vnc_send_clipboard(client,utf8,Int32(text.utf8.count),nil,-1)
                        }
                        DispatchQueue.main.async {self.onClipboardSent?(Int(result))}
                        sent=result<0 ? 1:result
                    }
                    if sent==0 { valid=false; break }
                }
                if !valid { break }
                if Date().timeIntervalSince(lastDecoded)<interval {Thread.sleep(forTimeInterval:0.005);continue}
                valid=deck_vnc_poll(client) != 0
                var clipboard: UnsafeRawPointer?,length: Int32=0,utf8: Int32=0
                if !clipboardPending,deck_vnc_take_clipboard(client,&clipboard,&length,&utf8) != 0,let clipboard {
                    let data=Data(bytes:clipboard,count:Int(length))
                    if let text=String(data:data,encoding:utf8 != 0 ? .utf8:.isoLatin1) {
                        lock.lock();pendingClipboard=true;lock.unlock()
                        DispatchQueue.main.async {
                            self.onClipboard?(text.trimmingCharacters(in:CharacterSet(charactersIn:"\0")))
                            self.lock.lock();self.pendingClipboard=false;self.lock.unlock()
                        }
                    }
                }
                let updated=deck_vnc_dirty(client) != 0
                if updated {lastDecoded=Date()}
                dirty = updated || dirty
                if dirty && !pending && Date().timeIntervalSince(last)>=interval {
                    let w=Int(deck_vnc_width(client)),h=Int(deck_vnc_height(client))
                    if let ptr=deck_vnc_pixels(client),w>0,h>0 {
                        sequence += 1
                        let frame=Frame(pixels:Data(bytes:ptr,count:w*h*4),width:w,height:h,sequence:sequence,time:Date())
                        lock.lock(); pendingFrame=true; lock.unlock()
                        DispatchQueue.main.async { [self] in
                            onFrame?(frame); lock.lock(); pendingFrame=false; lock.unlock()
                        }
                        dirty=false; last=Date()
                    }
                }
            }
            DispatchQueue.main.async { self.onClosed?(true,false) }
        }
    }
}
