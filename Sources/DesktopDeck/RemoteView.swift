import AppKit
import SwiftUI
import MetalKit
import DeckCore
import CVNC

@MainActor final class RemoteMetalView: MTKView, MTKViewDelegate {
    weak var session: DesktopSession? {
        didSet {
            if oldValue?.id != session?.id {
                promisedImage?.cancel();promisedImage=nil
                texture=nil;previousTexture=nil;sequence = -1;connectionRevision = -1
                blendTimer?.invalidate();blendTimer=nil;setNeedsDisplay(bounds)
                modifiers=[];downSymbols.removeAll();pointerPresses.removeAll();panRevision=nil
            }
        }
    }
    var interactive=false
    var focusRequest: KeyboardFocusRequest?
    var smoothPreview=true
    private var pipeline: MTLRenderPipelineState?
    private var commands: MTLCommandQueue?
    private var texture: MTLTexture?
    private var previousTexture: MTLTexture?
    private var blendStart=Date.distantPast
    private var blendTimer: Timer?
    private var sequence = -1
    private var connectionRevision = -1
    private var modifiers=NSEvent.ModifierFlags()
    private var downSymbols=[UInt16:(revision:Int,keys:[UInt32])]()
    private struct PointerRevision: Equatable {let connection: Int,geometry: Int}
    private var pointerPresses=[Int:PointerRevision]()
    private var panRevision: Int?
    private var promisedImage: PromisedImageDrop?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { interactive }
    // Keep the VNC mouse sequence inside this view, even under the hidden title bar.
    override var mouseDownCanMoveWindow: Bool { false }
    override var intrinsicContentSize: NSSize {NSSize(width:NSView.noIntrinsicMetric,height:NSView.noIntrinsicMetric)}
    init() {
        let device=MTLCreateSystemDefaultDevice()
        super.init(frame:.zero,device:device)
        isPaused=true; enableSetNeedsDisplay=true; framebufferOnly=true
        setContentHuggingPriority(.defaultLow,for:.horizontal);setContentHuggingPriority(.defaultLow,for:.vertical)
        setContentCompressionResistancePriority(.defaultLow,for:.horizontal);setContentCompressionResistancePriority(.defaultLow,for:.vertical)
        clearColor=MTLClearColorMake(0.035,0.04,0.05,1); delegate=self
        commands=device?.makeCommandQueue()
        let source="""
        #include <metal_stdlib>
        using namespace metal;
        struct V { float4 position [[position]]; float2 uv; };
        vertex V vertexMain(uint id [[vertex_id]], constant float4 *vertices [[buffer(0)]]) {
            V out; out.position=float4(vertices[id].xy,0,1); out.uv=vertices[id].zw; return out;
        }
        fragment float4 fragmentMain(V in [[stage_in]], texture2d<float> image [[texture(0)]], texture2d<float> previous [[texture(1)]], constant float &alpha [[buffer(0)]]) {
            constexpr sampler s(filter::linear,address::clamp_to_edge);
            return float4(mix(previous.sample(s,in.uv).rgb,image.sample(s,in.uv).rgb,alpha),1);
        }
        """
        do {
            let library=try device?.makeLibrary(source:source,options:nil)
            let descriptor=MTLRenderPipelineDescriptor(); descriptor.vertexFunction=library?.makeFunction(name:"vertexMain")
            descriptor.fragmentFunction=library?.makeFunction(name:"fragmentMain"); descriptor.colorAttachments[0].pixelFormat=colorPixelFormat
            pipeline=try device?.makeRenderPipelineState(descriptor:descriptor)
        } catch { session?.detail="Metal pipeline unavailable: \(error.localizedDescription)" }
        addTrackingArea(NSTrackingArea(rect:.zero,options:[.activeInKeyWindow,.inVisibleRect,.mouseMoved],owner:self))
        registerForDraggedTypes([.fileURL,.png,.tiff]+NSFilePromiseReceiver.readableDraggedTypes.map{NSPasteboard.PasteboardType($0)})
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func setFrameSize(_ newSize: NSSize) {super.setFrameSize(newSize);viewportChanged()}
    private func viewportChanged() {if interactive {session?.viewport=bounds.size;focusRequest?.schedule(on:self)};setNeedsDisplay(bounds)}
    func mtkView(_ view: MTKView,drawableSizeWillChange size: CGSize) {viewportChanged()}
    var transform: ViewTransform {
        ViewTransform(width:Double(bounds.width),height:Double(bounds.height),frameWidth:Double(session?.frame?.width ?? 1),frameHeight:Double(session?.frame?.height ?? 1),zoom:interactive ? session?.zoom ?? 1:1,panX:interactive ? Double(session?.pan.x ?? 0):0,panY:interactive ? Double(session?.pan.y ?? 0):0)
    }
    func draw(in view: MTKView) {
        guard let pass=currentRenderPassDescriptor,
              let drawable=currentDrawable,let command=commands?.makeCommandBuffer(),let encoder=command.makeRenderCommandEncoder(descriptor:pass) else { return }
        defer {encoder.endEncoding();command.present(drawable);command.commit()}
        guard let frame=session?.frame,let device,let pipeline,bounds.width>0,bounds.height>0 else {
            texture=nil;previousTexture=nil;sequence = -1;blendTimer?.invalidate();blendTimer=nil
            return
        }
        if texture?.width != frame.width || texture?.height != frame.height || connectionRevision != session?.connectionRevision {
            let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:frame.width,height:frame.height,mipmapped:false)
            texture=device.makeTexture(descriptor:descriptor); previousTexture=nil; sequence = -1
            connectionRevision=session?.connectionRevision ?? -1
        }
        if sequence != frame.sequence {
            if !interactive && smoothPreview && sequence != -1 {
                let prior=texture
                texture=previousTexture ?? device.makeTexture(descriptor:MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:frame.width,height:frame.height,mipmapped:false))
                previousTexture=prior; blendStart=Date()
                if blendTimer==nil {
                    blendTimer=Timer.scheduledTimer(withTimeInterval:1.0/30,repeats:true) { [weak self] timer in
                        MainActor.assumeIsolated {
                        guard let self else {timer.invalidate();return}
                        self.setNeedsDisplay(self.bounds)
                        if Date().timeIntervalSince(self.blendStart)>=0.07 {timer.invalidate();self.blendTimer=nil}
                        }
                    }
                }
            }
            frame.pixels.withUnsafeBytes { bytes in if let base=bytes.baseAddress { texture?.replace(region:MTLRegionMake2D(0,0,frame.width,frame.height),mipmapLevel:0,withBytes:base,bytesPerRow:frame.width*4) } }; sequence=frame.sequence
        }
        let t=transform,o=t.origin,w=Double(frame.width)*t.scale,h=Double(frame.height)*t.scale
        let x=Float(2*o.0/bounds.width-1),y=Float(1-2*o.1/bounds.height),rw=Float(2*w/bounds.width),rh=Float(2*h/bounds.height)
        let vertices:[SIMD4<Float>]=[.init(x,y,0,0),.init(x,y-rh,0,1),.init(x+rw,y,1,0),.init(x+rw,y-rh,1,1)]
        encoder.setRenderPipelineState(pipeline); encoder.setVertexBytes(vertices,length:MemoryLayout<SIMD4<Float>>.stride*4,index:0)
        var alpha: Float = !interactive && smoothPreview && previousTexture != nil ? Float(min(1,Date().timeIntervalSince(blendStart)/0.07)):1
        encoder.setFragmentTexture(texture,index:0); encoder.setFragmentTexture(previousTexture ?? texture,index:1)
        encoder.setFragmentBytes(&alpha,length:MemoryLayout<Float>.size,index:0)
        encoder.drawPrimitives(type:.triangleStrip,vertexStart:0,vertexCount:4)
    }
    private func point(_ event: NSEvent,clamp: Bool=false) -> (Int,Int)? {
        let location=convert(event.locationInWindow,from:nil);return transform.remote(x:location.x,y:location.y,clamp:clamp)
    }
    private func mouse(_ event: NSEvent,button: Int?,down: Bool?) {
        guard interactive,let s=session,s.active else {return}
        let revision=PointerRevision(connection:s.connectionRevision,geometry:s.geometry)
        if let button,down==false, pointerPresses.removeValue(forKey:button) != revision {return}
        let dragging=event.type == .leftMouseDragged || event.type == .rightMouseDragged || event.type == .otherMouseDragged
        if dragging && !pointerPresses.values.contains(revision) {return}
        guard let p=point(event,clamp:down==false || dragging) else {return}
        s.humanInput(invalidatePendingPaste:event.type != .mouseMoved)
        if let button,down==true {window?.makeFirstResponder(self);pointerPresses[button]=revision}
        var mask=s.mask
        if let button,let down { if down { mask |= button } else { mask &= ~button } }
        s.pointer(p.0,p.1,mask)
    }
    override func mouseDown(with e: NSEvent) {
        if e.modifierFlags.contains(.option),interactive,let session,session.active {
            window?.makeFirstResponder(self);session.humanInput();panRevision=session.connectionRevision
        } else {panRevision=nil;mouse(e,button:1,down:true)}
    }
    override func mouseUp(with e: NSEvent) {if panRevision != nil {panRevision=nil;return};mouse(e,button:1,down:false)}
    override func rightMouseDown(with e: NSEvent) { mouse(e,button:4,down:true) }
    override func rightMouseUp(with e: NSEvent) { mouse(e,button:4,down:false) }
    override func otherMouseDown(with e: NSEvent) { mouse(e,button:2,down:true) }
    override func otherMouseUp(with e: NSEvent) { mouse(e,button:2,down:false) }
    override func mouseMoved(with e: NSEvent) { mouse(e,button:nil,down:nil) }
    override func mouseDragged(with e: NSEvent) {
        if let panRevision {if let s=session,s.active,s.connectionRevision==panRevision {s.humanInput();s.pan.x += e.deltaX;s.pan.y += e.deltaY;setNeedsDisplay(bounds)}}
        else { mouse(e,button:nil,down:nil) }
    }
    override func rightMouseDragged(with e: NSEvent) { mouse(e,button:nil,down:nil) }
    override func otherMouseDragged(with e: NSEvent) {mouse(e,button:nil,down:nil)}
    override func scrollWheel(with e: NSEvent) {
        guard interactive,let s=session else { return }
        if e.modifierFlags.contains(.option) {s.humanInput();s.zoom=min(8,max(0.25,s.zoom*exp(-e.scrollingDeltaY*0.01))); setNeedsDisplay(bounds); return }
        guard let p=point(e) else { return }; s.humanInput()
        if e.scrollingDeltaY != 0 {s.scroll(p.0,p.1,up:e.scrollingDeltaY>0)}
    }
    override func magnify(with e: NSEvent) { guard let s=session else { return };s.humanInput();s.zoom=min(8,max(0.25,s.zoom*(1+e.magnification))); setNeedsDisplay(bounds) }
    override func resignFirstResponder() -> Bool {session?.releaseInput();modifiers=[];downSymbols.removeAll();pointerPresses.removeAll();panRevision=nil;return super.resignFirstResponder()}
    @objc func paste(_ sender: Any?) {modifiers=[];session?.pasteMacClipboard()}
    @objc func copy(_ sender: Any?) {modifiers=[];session?.shortcut([0xffe3,0x63])}
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow==nil {promisedImage?.cancel();promisedImage=nil}
        super.viewWillMove(toWindow:newWindow)
    }
    override func viewDidMoveToWindow() {super.viewDidMoveToWindow();if interactive {focusRequest?.schedule(on:self)}}
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard interactive,session?.active==true else {return []}
        return sender.draggingPasteboard.availableType(from:[.fileURL,.png,.tiff]) != nil || sender.draggingPasteboard.canReadObject(forClasses:[NSFilePromiseReceiver.self],options:nil) ? .copy:[]
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {draggingEntered(sender)}
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard interactive,let session,session.active else {return false}
        let location=convert(sender.draggingLocation,from:nil)
        guard transform.remote(x:location.x,y:location.y) != nil else {return false}
        do {
            promisedImage?.cancel();promisedImage=nil
            window?.makeKeyAndOrderFront(nil);NSApp.activate();window?.makeFirstResponder(self)
            guard let receiver=try PromisedImageDrop.receiver(from:sender.draggingPasteboard) else {
                guard let data=try ImageClipboard.read(sender.draggingPasteboard) else {session.showFeedback("Drop an image file");return false}
                session.pasteImage(data);return true
            }
            session.humanInput();let revision=session.connectionRevision,geometry=session.geometry,human=session.humanActionRevision
            promisedImage=try PromisedImageDrop(receiver) {[weak self,weak session] data,error in
                guard let self,let session else {return};self.promisedImage=nil
                if let error {session.showFeedback(error);return}
                guard self.session?.id==session.id,session.active,session.connectionRevision==revision,session.geometry==geometry,session.humanActionRevision==human,self.window?.firstResponder === self else {session.showFeedback("Image drop cancelled — screen changed");return}
                if let data {session.pasteImage(data)}
            }
            return true
        } catch {session.showFeedback(error.localizedDescription);return false}
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if interactive,window?.firstResponder === self,event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "v":paste(nil);return true
            case "c":copy(nil);return true
            default:break
            }
        }
        return super.performKeyEquivalent(with:event)
    }
    private func symbols(_ event: NSEvent) -> [UInt32] {
        let special:[UInt16:UInt32]=[36:0xff0d,48:0xff09,51:0xff08,53:0xff1b,117:0xffff,123:0xff51,124:0xff53,125:0xff54,126:0xff52,115:0xff50,119:0xff57,116:0xff55,121:0xff56,122:0xffbe,120:0xffbf,99:0xffc0,118:0xffc1,96:0xffc2,97:0xffc3,98:0xffc4,100:0xffc5,101:0xffc6,109:0xffc7,103:0xffc8,111:0xffc9]
        if let key=special[event.keyCode] { return [key] }
        return (event.charactersIgnoringModifiers ?? "").unicodeScalars.map { deck_vnc_keysym($0.value) }
    }
    override func keyDown(with e: NSEvent) {
        guard interactive,let s=session,s.active else {return};s.humanInput()
        let keys: [UInt32]
        if let binding=downSymbols[e.keyCode],binding.revision==s.connectionRevision {keys=binding.keys}
        else {keys=symbols(e)}
        downSymbols[e.keyCode]=(s.connectionRevision,keys)
        for key in keys {s.key(key,down:true)}
    }
    override func keyUp(with e: NSEvent) {
        guard interactive,let s=session,let binding=downSymbols.removeValue(forKey:e.keyCode),binding.revision==s.connectionRevision else {return}
        for key in binding.keys {s.key(key,down:false)}
    }
    override func flagsChanged(with e: NSEvent) {
        guard interactive,let s=session else { return }; s.humanInput(invalidatePendingPaste:false)
        for (flag,key):(NSEvent.ModifierFlags,UInt32) in [(.shift,0xffe1),(.control,0xffe3),(.option,0xffe9),(.command,0xffeb)] {
            if e.modifierFlags.contains(flag) != modifiers.contains(flag) { s.key(key,down:e.modifierFlags.contains(flag)) }
        }; modifiers=e.modifierFlags
    }
}
struct RemoteSurface: NSViewRepresentable {
    @ObservedObject var session: DesktopSession
    let interactive: Bool
    var focusRequest: KeyboardFocusRequest?=nil
    @AppStorage("previewSmoothing") private var smoothing=true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeNSView(context: Context) -> RemoteMetalView { let view=RemoteMetalView(); view.session=session; return view }
    func sizeThatFits(_ proposal: ProposedViewSize,nsView: RemoteMetalView,context: Context) -> CGSize? {
        guard let width=proposal.width,let height=proposal.height,width.isFinite,height.isFinite else {return nil}
        return CGSize(width:max(0,width),height:max(0,height))
    }
    func updateNSView(_ view: RemoteMetalView,context: Context) {
        if view.session?.id != session.id,let previous=view.session,previous.inputView === view {previous.releaseInput();previous.inputView=nil}
        view.session=session;view.interactive=interactive
        view.focusRequest=interactive ? focusRequest:nil
        if interactive {session.inputView=view;session.viewport=view.bounds.size}
        else if session.inputView === view {session.inputView=nil}
        view.smoothPreview=smoothing && !reduceMotion;view.setNeedsDisplay(view.bounds)
        view.focusRequest?.schedule(on:view)
    }
    static func dismantleNSView(_ view: RemoteMetalView,coordinator: ()) {
        if let previous=view.session,previous.inputView === view {previous.releaseInput();previous.inputView=nil}
        view.focusRequest=nil;view.session=nil
    }
}
@MainActor extension DesktopSession {
    var viewState: [String:Any] {
        let view=inputView.flatMap{$0.session?.id==id && $0.interactive && $0.window != nil ? $0:nil}
        let size=view?.bounds.size ?? viewport,visible=view.map{$0.bounds.intersection($0.visibleRect).size} ?? size
        return ["attached":view != nil,"focused":view?.ownsKeyboardFocus ?? false,"viewportWidth":size.width,"viewportHeight":size.height,"visibleWidth":visible.width,"visibleHeight":visible.height,"zoom":zoom,"panX":pan.x,"panY":pan.y]
    }
}
