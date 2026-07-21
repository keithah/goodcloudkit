import SwiftUI

/// A small capsule badge showing a device's online/offline state.
struct StatusPill: View {
    let isOnline: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isOnline ? "wifi" : "wifi.slash")
                .font(.caption2)
            Text(isOnline ? "Online" : "Offline")
                .font(.caption)
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(isOnline ? Theme.success : Theme.secondaryText.opacity(0.25))
        .foregroundStyle(isOnline ? Color.white : Theme.secondaryText)
        .clipShape(Capsule())
    }
}
