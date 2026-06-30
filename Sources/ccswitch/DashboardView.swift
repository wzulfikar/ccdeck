import SwiftUI

/// The windowed view shown at launch. Wraps the same content as the menu so there's
/// a single source of truth, with a banner explaining the app keeps running when closed.
struct DashboardView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ccswitch is running").font(.headline)
                    Text("Lives in the menu bar (top right). Close this window anytime — it keeps running.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding()

            Divider()

            MenuView(model: model)
        }
        .frame(width: 360)
    }
}
