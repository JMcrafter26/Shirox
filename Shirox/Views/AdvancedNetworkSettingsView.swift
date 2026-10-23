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
        } header: {
            Text("TMDB")
        } footer: {
            Text("Bypasses regional access blocks and restrictions in regions like Russia, India, and China by routing TMDB traffic through your own endpoints.")
        }
        if useProxies {
            Section {
                addressField("Custom API Base URL", text: $apiBase, prompt: TMDBHostSettings.defaultAPIBase)
                addressField("Custom Image Base URL", text: $imageBase, prompt: TMDBHostSettings.defaultImageBase)
            } footer: {
                Text(footer)
            }
        }
    }

    private var footer: String {
        let explanation = "Each replaces https://api.themoviedb.org or https://image.tmdb.org; the path and query, TMDB's key included, go to your endpoint. While this is on, TMDB traffic goes only there, and none is sent without a valid https address."
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
        } header: {
            Text("DNS over HTTPS")
        } footer: {
            Text("Looks up every server the app talks to over an encrypted DNS server of your choice, for networks that tamper with DNS. Video playback and web views aren't covered: they run in the system's own processes. A DNS profile or VPN set on the device comes first. Takes effect the next time Shirox starts.")
        }
        if secureDNS {
            Section {
                addressField("Server URL", text: $serverURL, prompt: SecureDNSSettings.defaultServerURL)
                addressField("Server IP Addresses", text: $serverAddresses, prompt: SecureDNSSettings.defaultServerAddresses)
            } footer: {
                Text(footer)
            }
        }
    }

    private var footer: String {
        let explanation = "Cloudflare: https://cloudflare-dns.com/dns-query at 1.1.1.1. Google: https://dns.google/dns-query at 8.8.8.8. The addresses reach the server without a lookup of its own. If the server can't be reached, nothing in the app loads; turn this off to recover."
        let usable = SecureDNSSettings(enabled: true, serverURL: serverURL, serverAddresses: serverAddresses).resolver != nil
        return usable ? explanation : "Needs an https URL and at least one IP address; until then it stays off. " + explanation
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
        } header: {
            Text("Proxy")
        } footer: {
            Text(NetworkProxy.isSupported
                 ? "Sends the app's requests, modules' and web views' included, through your HTTP CONNECT or SOCKS5 proxy. Video playback isn't covered: the players open their own connections. Nothing goes out directly while the proxy is down. Takes effect the next time Shirox starts."
                 : "A proxy for all traffic needs iOS 17, macOS 14 or tvOS 17.")
        }
        if enabled {
            Section {
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
            } footer: {
                Text(footer)
            }
        }
    }

    private var footer: String {
        let settings = NetworkProxySettings(enabled: true, kind: kind, host: host, port: port,
                                            username: username, password: password)
        let explanation = "The password is kept in the Keychain."
        return settings.server == nil
            ? "Needs a host name or IP address and a port, and a password with a username; until then it stays off. " + explanation
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
        } header: {
            Text("User-Agent")
        } footer: {
            Text("The browser Shirox says it is to websites: on module requests, images and web views. A module that picks a browser of its own, and a solved Cloudflare check, keep theirs. Some sites turn away an old or unusual one.")
        }
        if enabled {
            Section {
                addressField("User-Agent", text: $userAgent, prompt: NetworkUserAgent.standard)
                Button("Use Shirox's Own") { userAgent = NetworkUserAgent.standard }
                    .disabled(userAgent == NetworkUserAgent.standard)
            } footer: {
                Text("Shirox's own: \(NetworkUserAgent.standard)")
            }
        }
    }
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
            Text("Checks TMDB's API and images the way Shirox reaches them now, then the encrypted DNS server and the proxy, if they're on. For the proxy it asks Cloudflare which address it sees requests come from. DNS and proxy changes are only in use after the next start.")
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
            Text("Forgets cookies and website data, the web cache, solved Cloudflare checks and which TMDB host answered. Your settings here stay as they are.")
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
