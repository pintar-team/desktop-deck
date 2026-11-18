import SwiftUI
import DeckCore

struct CompactGrid: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            let items=model.visible
            let mode=model.workspace.gridMode ?? 0
            let grid=GridLayout(count:items.count,width:geometry.size.width,height:geometry.size.height,fixed:mode)
            let cellW=max(1,geometry.size.width/CGFloat(grid.columns))
            let cellH=mode>0 ? cellW/1.6 : max(1,geometry.size.height/CGFloat(grid.rows))
            if mode>0 {
                ScrollView {
                    LazyVGrid(columns:Array(repeating:GridItem(.flexible(minimum:0),spacing:0),count:grid.columns),spacing:0) {
                        ForEach(items) { s in DesktopTile(session:s,model:model).frame(height:cellH) }
                    }
                }
            } else {
                VStack(spacing:0) {
                    ForEach(0..<grid.rows,id:\.self) { row in
                        HStack(spacing:0) {
                            ForEach(0..<grid.columns,id:\.self) { column in
                                let index=row*grid.columns+column
                                if index<items.count { DesktopTile(session:items[index],model:model).frame(width:cellW,height:cellH) }
                                else { Color.clear.frame(width:cellW,height:cellH) }
                            }
                        }
                    }
                }
            }
        }.background(DeckTheme.background).animation(reduceMotion ? nil:.smooth(duration:0.18),value:model.workspace.profiles)
    }
}
