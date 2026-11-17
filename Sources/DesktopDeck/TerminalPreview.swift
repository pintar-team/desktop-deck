import SwiftUI
import AppKit

struct TerminalPreview: View {
    @ObservedObject var session: DesktopSession
    var body: some View {
        TimelineView(.periodic(from:.now,by:1)) {_ in
            if let tab=session.selectedTab,let snapshot=tab.view.terminalContentSnapshot(region:.viewport) {
                let font=tab.view.font
                Canvas {context,size in
                    let lines=snapshot.rows.map {context.resolve(Text($0.text).font(Font(font)).foregroundColor(session.tint.opacity(0.9)))}
                    let measured=lines.map{$0.measure(in:CGSize(width:CGFloat.infinity,height:CGFloat.infinity))}
                    let cellWidth=("M" as NSString).size(withAttributes:[.font:font]).width
                    let lineHeight=max(ceil(font.ascender-font.descender+font.leading),measured.map(\.height).max() ?? 1)
                    let width=max(CGFloat(max(1,snapshot.dimensions.cols))*cellWidth,measured.map(\.width).max() ?? 1)
                    let height=CGFloat(max(1,snapshot.dimensions.rows))*lineHeight
                    let scale=min(size.width/width,size.height/height)
                    context.translateBy(x:(size.width-width*scale)/2,y:(size.height-height*scale)/2)
                    context.scaleBy(x:scale,y:scale)
                    for (row,line) in lines.enumerated() {context.draw(line,at:CGPoint(x:0,y:CGFloat(row)*lineHeight),anchor:.topLeading)}
                }.padding(.horizontal,6).padding(.top,24).padding(.bottom,20)
            } else {Image(systemName:"terminal").font(.system(size:28,weight:.light)).foregroundStyle(session.tint.opacity(0.5)).frame(maxWidth:.infinity,maxHeight:.infinity)}
        }
    }
}
