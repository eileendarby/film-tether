import SwiftUI

enum EmptyStates {

    struct NoCamera: View {
        var body: some View {
            VStack(spacing: 16) {
                Image(systemName: "camera.metering.unknown")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Connect a compatible camera")
                    .font(.title2)
                Text("USB cable, camera powered on.\nSet the Communication menu to PTP if you've changed it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Link("See supported cameras", destination: AppInfo.supportedCamerasURL)
                    .font(.subheadline)
            }
            .padding(40)
        }
    }

    struct ErrorState: View {
        let message: String
        let hint: String?

        var body: some View {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                if let hint {
                    Text(hint)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
            .padding(40)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
