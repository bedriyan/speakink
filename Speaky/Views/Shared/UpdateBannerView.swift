import SwiftUI

struct UpdateBannerView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if appState.updateService.hasUpdate,
           let release = appState.updateService.availableUpdate {
            let version = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))

            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(Theme.amber)
                    .font(.system(size: 14))

                Text("Speaky \(version) is available")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)

                Spacer()

                Button("Download") {
                    if let url = appState.updateService.downloadURL() {
                        NSWorkspace.shared.open(url)
                    }
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.amber)
                .buttonStyle(.handCursor)

                Button {
                    appState.updateService.dismissUpdate()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.handCursor)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.amber.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Theme.amber.opacity(0.2), lineWidth: 1)
            )
            .padding(.horizontal, 20)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
