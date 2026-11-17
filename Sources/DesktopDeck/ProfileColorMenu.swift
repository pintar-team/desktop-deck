import SwiftUI

struct ProfileColorMenu: View {
    @ObservedObject var session: DesktopSession
    @ObservedObject var model: WorkspaceModel
    var body: some View {
        Menu("Accent color") {
            Button("Automatic") {session.profile.tintHex=nil;model.persist()}
            Divider()
            ForEach(DeckTheme.palette,id:\.hex) { swatch in
                Button {session.profile.tintHex=swatch.hex;model.persist()} label:{Label(swatch.name,systemImage:"circle.fill").foregroundStyle(DeckTheme.color(swatch.hex))}
            }
        }
    }
}
