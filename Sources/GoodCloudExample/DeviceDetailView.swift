import SwiftUI
import GoodCloudKit

struct DeviceDetailView: View {
    @ObservedObject var model: AppModel
    let device: GoodCloudDevice

    @State private var useHTTPS = false
    @State private var portText = "80"
    @State private var path = ""
    @State private var isSending = false
    @State private var outcome: RelayOutcome?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                remoteAccessSection
                if let outcome {
                    resultSection(outcome)
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.pageBackground)
        .navigationTitle(device.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.name)
                        .font(.title2)
                        .fontWeight(.bold)
                    Text(device.model)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                StatusPill(isOnline: device.isOnline)
            }

            Divider()

            LabeledRow(icon: "number", label: "MAC", value: device.mac, monospaced: true)
            if let ddns = device.ddns, !ddns.isEmpty {
                LabeledRow(icon: "network", label: "DDNS", value: ddns, monospaced: true)
            }
            if let mode = device.networkMode, !mode.isEmpty {
                LabeledRow(icon: "wifi.router", label: "Network", value: mode, monospaced: false)
            }
        }
        .cardStyle()
    }

    // MARK: - Remote access

    private var remoteAccessSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Remote Access", systemImage: "lock.shield")
                .font(.headline)

            Picker("Protocol", selection: $useHTTPS) {
                Text("HTTP").tag(false)
                Text("HTTPS").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 6) {
                Text("Port")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                TextField("80", text: $portText)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .textFieldStyle(.roundedBorder)
                Text("Default 80 (router admin); any LAN port works")
                    .font(.caption2)
                    .foregroundStyle(Theme.secondaryText)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Path")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                TextField("/", text: $path)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
            }

            Button(action: send) {
                HStack(spacing: 8) {
                    if isSending {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                    Text(isSending ? "Sending…" : "Send Request")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!device.isOnline || isSending || Int(portText) == nil)

            if !device.isOnline {
                HStack(spacing: 6) {
                    Image(systemName: "wifi.slash")
                    Text("Device is offline — remote access is unavailable.")
                }
                .font(.caption)
                .foregroundStyle(Theme.danger)
            }
        }
        .cardStyle()
    }

    // MARK: - Result

    private func resultSection(_ outcome: RelayOutcome) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Result", systemImage: "doc.text.magnifyingglass")
                .font(.headline)

            switch outcome {
            case .success(let result):
                HStack(spacing: 8) {
                    Text("HTTP \(result.statusCode)")
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .foregroundStyle((200..<300).contains(result.statusCode) ? Theme.success : Theme.danger)
                    Text("· \(result.byteCount) bytes")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                }

                LabeledRow(icon: "globe", label: "Relay Host", value: result.relayHost, monospaced: true)
                LabeledRow(icon: "key.fill", label: "Relay Token",
                          value: result.hasRelayToken ? "captured" : "none", monospaced: false)

                ScrollView {
                    Text(result.bodyPreview)
                        .font(.caption)
                        .fontDesign(.monospaced)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                }
                .frame(maxHeight: 220)
                .background(Theme.pageBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            case .failure(let message):
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(message)
                }
                .font(.subheadline)
                .foregroundStyle(Theme.danger)
            }
        }
        .cardStyle()
    }

    private func send() {
        guard let port = Int(portText) else { return }
        isSending = true
        outcome = nil
        let proto: RelayProtocol = useHTTPS ? .https : .http
        Task {
            let result = await model.sendRelayRequest(device: device, proto: proto, port: port, path: path)
            outcome = result
            isSending = false
        }
    }
}

private struct LabeledRow: View {
    let icon: String
    let label: String
    let value: String
    var monospaced: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 18)
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.caption)
                .fontDesign(monospaced ? .monospaced : .default)
                .textSelection(.enabled)
            Spacer()
        }
    }
}
