import SwiftUI

struct MenuView: View {
    @ObservedObject var manager: AccountManager

    var body: some View {
        GlassDashboardView(manager: manager)
    }
}
