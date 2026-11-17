import AppKit
import Foundation

let source=URL(fileURLWithPath:CommandLine.arguments[1])
let target=URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true)
guard let input=NSImage(contentsOf:source) else {fatalError("Icon source unavailable")}
try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels=size*scale
        guard let output=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),let context=NSGraphicsContext(bitmapImageRep:output) else {fatalError("Icon context unavailable")}
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=context;context.imageInterpolation = .high
        input.draw(in:NSRect(x:0,y:0,width:pixels,height:pixels),from:.zero,operation:.copy,fraction:1)
        NSGraphicsContext.restoreGraphicsState()
        let name="icon_\(size)x\(size)\(scale==2 ? "@2x":"").png"
        try output.representation(using:.png,properties:[:])!.write(to:target.appendingPathComponent(name))
    }
}
