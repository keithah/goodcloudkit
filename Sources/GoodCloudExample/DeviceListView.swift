import SwiftUI
import GoodCloudKit

struct DeviceListView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if model.isLoadingDevices && model.devices.isEmpty {
                loadingState
            } else if let error = model.devicesError, model.devices.isEmpty {
                errorState(error)
            } else if model.devices.isEmpty {
                emptyState
            } else {
                deviceList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.pageBackground)
        .navigationTitle("Devices")
        .toolbar {
            ToolbarItem(placement: .automatic) { refreshButton }
            ToolbarItem(placement: .automatic) { logOutButton }
        }
        .task { await model.loadDevices() }
    }

    private var refreshButton: some View {
        Button {
            Task { await model.loadDevices() }
        } label: {
            if model.isLoadingDevices {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .disabled(model.isLoadingDevices)
        .help("Refresh devices")
    }

    private var logOutButton: some View {
        Menu {
            Button {
                Task { await model.logOut() }
            } label: {
                Label("Log Out (this app)", systemImage: "rectangle.portrait.and.arrow.right")
            }
            Button(role: .destructive) {
                Task { await model.logOutEverywhere() }
            } label: {
                Label("Log Out Everywhere", systemImage: "xmark.shield")
            }
        } label: {
            Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
        }
        .help("Log out")
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading devices…")
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(Theme.danger)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.secondaryText)
            Button("Try Again") { Task { await model.loadDevices() } }
                .buttonStyle(PrimaryButtonStyle())
                .frame(maxWidth: 200)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.largeTitle)
                .foregroundStyle(Theme.secondaryText)
            Text("No Devices")
                .font(.headline)
            Text("Routers bound to your GoodCloud account will appear here.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            Button("Refresh") { Task { await model.loadDevices() } }
                .buttonStyle(PrimaryButtonStyle())
                .frame(maxWidth: 200)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var deviceList: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(model.devices) { device in
                    NavigationLink {
                        DeviceDetailView(model: model, device: device)
                    } label: {
                        DeviceCard(device: device)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
        .refreshable { await model.loadDevices() }
    }
}

private struct DeviceCard: View {
    let device: GoodCloudDevice

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.title2)
                .foregroundStyle(Theme.accent)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(device.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(device.model)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                Text(device.mac)
                    .font(.caption)
                    .fontDesign(.monospaced)
                    .foregroundStyle(Theme.secondaryText)
            }

            Spacer()

            StatusPill(isOnline: device.isOnline)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
        }
        .cardStyle()
    }
}
