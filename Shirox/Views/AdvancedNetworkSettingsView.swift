import SwiftUI

// TODO: Custom base URLs for other blocked services (AniList, Jikan, MyAnimeList), through the
// same kind of rewrite `TMDBHosts` does for TMDB.

/// Expert settings for regions where TMDB, DNS or more is blocked, kept out of the way at the
/// end of Settings: custom TMDB proxies (`TMDBHosts`), encrypted DNS (`SecureDNS`), a proxy for
/// all traffic (`NetworkProxy`), the User-Agent (`NetworkUserAgent`), a connection test
/// (`NetworkDiagnostics`) and a reset (`NetworkReset`).
struct AdvancedNetworkSettingsView: View {
    var body: some View {
        SettingsList {
            TMDBProxySections()
            SecureDNSSections()
            ProxySections()
            UserAgentSections()
            ConnectionTestSection()
            NetworkResetSection()
        }
        .softScrollEdges()
        .navigationTitle("Advanced Network")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// A toggle's explanation as a row under it, the way Player settings lays them out. Each
/// section here shows its explanation as the footer while its toggle is off; once it's on,
/// the explanation moves up into a row so the toggle and the settings it reveals stay one group.
private func noteRow(_ text: String) -> some View {
    Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
}

/// A text field for an address: no autocorrection or capitals, the URL keyboard.
private func addressField(_ title: String, text: Binding<String>, prompt: String? = nil) -> some View {
    TextField(title, text: text, prompt: prompt.map { Text($0) })
        .autocorrectionDisabled()
        #if os(iOS)
        .textInputAutocapitalization(.never)
        .keyboardType(.URL)
        #endif
}

// MARK: - TMDB

private struct TMDBProxySections: View {
    @AppStorage(TMDBHostSettings.useProxiesKey) private var useProxies = false
    @AppStorage(TMDBHostSettings.apiBaseKey) private var apiBase = ""
    @AppStorage(TMDBHostSettings.imageBaseKey) private var imageBase = ""

    var body: some View {
        Section {
            Toggle("Use Custom TMDB Proxies", isOn: $useProxies)
                .tint(.secondary)
                .onChangeOf(useProxies) { isOn in
                    guard isOn else { return }
                    if apiBase.isEmpty { apiBase = TMDBHostSettings.defaultAPIBase }
                    if imageBase.isEmpty { imageBase = TMDBHostSettings.defaultImageBase }
                }
            if useProxies {
                noteRow(Self.note)
                addressField("Custom API Base URL", text: $apiBase, prompt: TMDBHostSettings.defaultAPIBase)
                addressField("Custom Image Base URL", text: $imageBase, prompt: TMDBHostSettings.defaultImageBase)
            }
        } header: {
            Text("TMDB")
        } footer: {
            Text(useProxies ? footer : Self.note)
        }
    }

    private static let note = "Routes TMDB traffic through your own endpoints, for regions that block it."

    private var footer: String {
        let explanation = "Replaces https://api.themoviedb.org and https://image.tmdb.org; the path, query and key go along. TMDB traffic then goes only there, and only to a valid https address."
        let invalid = [("API", apiBase), ("image", imageBase)]
            .filter { TMDBHostSettings.validBase($0.1) == nil }
            .map(\.0)
        guard !invalid.isEmpty else { return explanation }
        return "No valid \(invalid.joined(separator: " or ")) address yet. " + explanation
    }
}

// MARK: - DNS

private struct SecureDNSSections: View {
    @AppStorage(SecureDNSSettings.enabledKey) private var secureDNS = false
    @AppStorage(SecureDNSSettings.serverURLKey) private var serverURL = ""
    @AppStorage(SecureDNSSettings.serverAddressesKey) private var serverAddresses = ""

    var body: some View {
        Section {
            Toggle("Encrypted DNS", isOn: $secureDNS)
                .tint(.secondary)
                .onChangeOf(secureDNS) { isOn in
                    guard isOn else { return }
                    if serverURL.isEmpty { serverURL = SecureDNSSettings.defaultServerURL }
                    if serverAddresses.isEmpty { serverAddresses = SecureDNSSettings.defaultServerAddresses }
                }
            if secureDNS {
                noteRow(Self.note)
                addressField("Server URL", text: $serverURL, prompt: SecureDNSSettings.defaultServerURL)
                addressField("Server IP Addresses", text: $serverAddresses, prompt: SecureDNSSettings.defaultServerAddresses)
            }
        } header: {
            Text("DNS over HTTPS")
        } footer: {
            Text(secureDNS ? footer : Self.note)
        }
    }

    private static let note = "Looks up servers over encrypted DNS, for networks that tamper with it. Not for video or web views; a device DNS profile or VPN comes first. Applies after a restart."

    private var footer: String {
        let explanation = "Cloudflare: https://cloudflare-dns.com/dns-query at 1.1.1.1. Google: https://dns.google/dns-query at 8.8.8.8. If the server can't be reached, nothing loads; turn this off to recover."
        let usable = SecureDNSSettings(enabled: true, serverURL: serverURL, serverAddresses: serverAddresses).resolver != nil
        return usable ? explanation : "Needs an https URL and an IP address; off until then. " + explanation
    }
}

// MARK: - Proxy

private struct ProxySections: View {
    @AppStorage(NetworkProxySettings.enabledKey) private var enabled = false
    @AppStorage(NetworkProxySettings.kindKey) private var kindValue = NetworkProxySettings.Kind.socks5.rawValue
    @AppStorage(NetworkProxySettings.hostKey) private var host = ""
    @AppStorage(NetworkProxySettings.portKey) private var port = ""
    @AppStorage(NetworkProxySettings.usernameKey) private var username = ""
    /// In the Keychain, not in `@AppStorage`.
    @State private var password = ProxyKeychain.read(NetworkProxySettings.passwordAccount) ?? ""

    private var kind: NetworkProxySettings.Kind { NetworkProxySettings.Kind(rawValue: kindValue) ?? .socks5 }

    var body: some View {
        Section {
            Toggle("Proxy All Traffic", isOn: $enabled)
                .tint(.secondary)
                .onChangeOf(enabled) { isOn in
                    if isOn, port.isEmpty { port = kind.defaultPort }
                }
            if enabled {
                noteRow(Self.note)
                Picker("Type", selection: $kindValue) {
                    ForEach(NetworkProxySettings.Kind.allCases, id: \.rawValue) { kind in
                        Text(kind.title).tag(kind.rawValue)
                    }
                }
                .onChangeOf(kindValue) { _ in
                    // A port that was the other type's default follows the type.
                    if NetworkProxySettings.Kind.allCases.contains(where: { $0.defaultPort == port }) { port = kind.defaultPort }
                }
                addressField("Host", text: $host, prompt: "proxy.example.com")
                TextField("Port", text: $port, prompt: Text(kind.defaultPort))
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                addressField("Username", text: $username, prompt: "Optional")
                SecureField("Password", text: $password, prompt: Text("Optional"))
                    .onChangeOf(password) { ProxyKeychain.save($0, account: NetworkProxySettings.passwordAccount) }
            }
        } header: {
            Text("Proxy")
        } footer: {
            Text(enabled ? footer : Self.note)
        }
    }

    private static var note: String {
        NetworkProxy.isSupported
            ? "Sends app, module and web view requests through an HTTP CONNECT or SOCKS5 proxy. Not for video. Nothing goes out directly while it's down. Applies after a restart."
            : "A proxy for all traffic needs iOS 17, macOS 14 or tvOS 17."
    }

    private var footer: String {
        let settings = NetworkProxySettings(enabled: true, kind: kind, host: host, port: port,
                                            username: username, password: password)
        let explanation = "The password is kept in the Keychain."
        return settings.server == nil
            ? "Needs a host and port, and a password with a username; off until then. " + explanation
            : explanation
    }
}

// MARK: - User-Agent

private struct UserAgentSections: View {
    @AppStorage(NetworkUserAgent.enabledKey) private var enabled = false
    @AppStorage(NetworkUserAgent.valueKey) private var userAgent = ""

    var body: some View {
        Section {
            Toggle("Custom User-Agent", isOn: $enabled)
                .tint(.secondary)
                .onChangeOf(enabled) { isOn in
                    if isOn, userAgent.isEmpty { userAgent = NetworkUserAgent.standard }
                }
            if enabled {
                noteRow(Self.note)
                addressField("User-Agent", text: $userAgent, prompt: NetworkUserAgent.standard)
                Button("Use Shirox's Own") { userAgent = NetworkUserAgent.standard }
                    .disabled(userAgent == NetworkUserAgent.standard)
            }
        } header: {
            Text("User-Agent")
        } footer: {
            Text(enabled ? "Shirox's own: \(NetworkUserAgent.standard)" : Self.note)
        }
    }

    private static let note = "The browser Shirox claims to be for modules, images and web views. Modules with their own, and solved Cloudflare checks, keep theirs."
}

// MARK: - Test

private struct ConnectionTestSection: View {
    @State private var checks: [NetworkCheck] = []
    @State private var isTesting = false

    var body: some View {
        Section {
            Button(action: test) {
                HStack {
                    Text("Test Connection")
                    Spacer()
                    if isTesting { ProgressView() }
                }
            }
            .disabled(isTesting)
            ForEach(checks) { check in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: icon(for: check.outcome))
                        .foregroundStyle(color(for: check.outcome))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(check.title)
                        Text(check.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } footer: {
            Text("Checks TMDB's API and images, then encrypted DNS and the proxy if they're on, asking Cloudflare which address it sees. DNS and proxy changes apply after a restart.")
        }
    }

    private func test() {
        isTesting = true
        checks = []
        Task {
            let diagnostics = NetworkDiagnostics(dnsInUse: SecureDNS.active, proxyInUse: NetworkProxy.active)
            checks = await diagnostics.run()
            isTesting = false
        }
    }

    private func icon(for outcome: NetworkCheck.Outcome) -> String {
        switch outcome {
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .skipped: return "minus.circle"
        }
    }

    private func color(for outcome: NetworkCheck.Outcome) -> Color {
        switch outcome {
        case .passed: return .green
        case .failed: return .red
        case .skipped: return .secondary
        }
    }
}

// MARK: - Reset

private struct NetworkResetSection: View {
    @State private var confirm = false
    @State private var isResetting = false
    @State private var didReset = false

    var body: some View {
        Section {
            Button(role: .destructive) {
                confirm = true
            } label: {
                HStack {
                    Text(didReset ? "Network State Reset" : "Reset Network State")
                    Spacer()
                    if isResetting { ProgressView() }
                }
            }
            .foregroundStyle(.red)
            .disabled(isResetting)
            .confirmationDialog("Reset Network State?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Reset", role: .destructive, action: reset)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Signs Shirox out of websites and forgets solved Cloudflare checks; modules may ask you to verify again.")
            }
        } footer: {
            Text("Clears cookies, website data, the web cache, solved Cloudflare checks and the remembered TMDB host. Settings here stay.")
        }
    }

    private func reset() {
        isResetting = true
        Task {
            await NetworkReset.resetAll()
            isResetting = false
            didReset = true
        }
    }
}
