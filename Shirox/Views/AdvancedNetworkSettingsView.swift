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
        .navigationTitle("settings.advanced_network")
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
            Toggle("settings.use_custom_tmdb_proxies", isOn: $useProxies)
                .switchTint()
                .onChangeOf(useProxies) { isOn in
                    guard isOn else { return }
                    if apiBase.isEmpty { apiBase = TMDBHostSettings.defaultAPIBase }
                    if imageBase.isEmpty { imageBase = TMDBHostSettings.defaultImageBase }
                }
            if useProxies {
                noteRow(Self.note)
                addressField(String(localized: "settings.custom_api_base_url"), text: $apiBase, prompt: TMDBHostSettings.defaultAPIBase)
                addressField(String(localized: "settings.custom_image_base_url"), text: $imageBase, prompt: TMDBHostSettings.defaultImageBase)
            }
        } header: {
            Text("TMDB")
        } footer: {
            Text(useProxies ? footer : Self.note)
        }
    }

    private static let note = String(localized: "settings.routes_tmdb_traffic_through_your")

    private var footer: String {
        let explanation = String(localized: "settings.replaces_https_api_themoviedb_org")
        let apiValid = TMDBHostSettings.validBase(apiBase) != nil
        let imageValid = TMDBHostSettings.validBase(imageBase) != nil
        switch (apiValid, imageValid) {
        case (true, true):   return explanation
        case (false, true):  return String(localized: "settings.no_valid_api_address_yet") + " " + explanation
        case (true, false):  return String(localized: "settings.no_valid_image_address_yet") + " " + explanation
        case (false, false): return String(localized: "settings.no_valid_api_or_image") + " " + explanation
        }
    }
}

// MARK: - DNS

private struct SecureDNSSections: View {
    @AppStorage(SecureDNSSettings.enabledKey) private var secureDNS = false
    @AppStorage(SecureDNSSettings.serverURLKey) private var serverURL = ""
    @AppStorage(SecureDNSSettings.serverAddressesKey) private var serverAddresses = ""

    var body: some View {
        Section {
            Toggle("settings.encrypted_dns", isOn: $secureDNS)
                .switchTint()
                .onChangeOf(secureDNS) { isOn in
                    guard isOn else { return }
                    if serverURL.isEmpty { serverURL = SecureDNSSettings.defaultServerURL }
                    if serverAddresses.isEmpty { serverAddresses = SecureDNSSettings.defaultServerAddresses }
                }
            if secureDNS {
                noteRow(Self.note)
                addressField(String(localized: "settings.server_url"), text: $serverURL, prompt: SecureDNSSettings.defaultServerURL)
                addressField(String(localized: "settings.server_ip_addresses"), text: $serverAddresses, prompt: SecureDNSSettings.defaultServerAddresses)
            }
        } header: {
            Text("settings.dns_over_https")
        } footer: {
            Text(secureDNS ? footer : Self.note)
        }
    }

    private static let note = String(localized: "settings.looks_up_servers_over_encrypted")

    private var footer: String {
        let explanation = String(localized: "settings.cloudflare_https_cloudflare_dns_com")
        let usable = SecureDNSSettings(enabled: true, serverURL: serverURL, serverAddresses: serverAddresses).resolver != nil
        return usable ? explanation : String(localized: "settings.needs_https_url_footer") + explanation
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
            Toggle("settings.proxy_all_traffic", isOn: $enabled)
                .switchTint()
                .onChangeOf(enabled) { isOn in
                    if isOn, port.isEmpty { port = kind.defaultPort }
                }
            if enabled {
                noteRow(Self.note)
                Picker("settings.type", selection: $kindValue) {
                    ForEach(NetworkProxySettings.Kind.allCases, id: \.rawValue) { kind in
                        Text(kind.title).tag(kind.rawValue)
                    }
                }
                .onChangeOf(kindValue) { _ in
                    // A port that was the other type's default follows the type.
                    if NetworkProxySettings.Kind.allCases.contains(where: { $0.defaultPort == port }) { port = kind.defaultPort }
                }
                addressField(String(localized: "settings.host"), text: $host, prompt: "proxy.example.com")
                TextField("settings.port", text: $port, prompt: Text(kind.defaultPort))
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                addressField(String(localized: "settings.username"), text: $username, prompt: String(localized: "settings.optional"))
                SecureField("settings.password", text: $password, prompt: Text("settings.optional"))
                    .onChangeOf(password) { ProxyKeychain.save($0, account: NetworkProxySettings.passwordAccount) }
            }
        } header: {
            Text("settings.proxy")
        } footer: {
            Text(enabled ? footer : Self.note)
        }
    }

    private static var note: String {
        NetworkProxy.isSupported
            ? String(localized: "settings.sends_app_module_and_web")
            : String(localized: "settings.a_proxy_for_all_traffic")
    }

    private var footer: String {
        let settings = NetworkProxySettings(enabled: true, kind: kind, host: host, port: port,
                                            username: username, password: password)
        let explanation = String(localized: "settings.the_password_is_kept_in")
        return settings.server == nil
            ? String(localized: "settings.needs_a_host_and_port") + explanation
            : explanation
    }
}

// MARK: - User-Agent

private struct UserAgentSections: View {
    @AppStorage(NetworkUserAgent.enabledKey) private var enabled = false
    @AppStorage(NetworkUserAgent.valueKey) private var userAgent = ""

    var body: some View {
        Section {
            Toggle("settings.custom_user_agent", isOn: $enabled)
                .switchTint()
                .onChangeOf(enabled) { isOn in
                    if isOn, userAgent.isEmpty { userAgent = NetworkUserAgent.standard }
                }
            if enabled {
                noteRow(Self.note)
                addressField("User-Agent", text: $userAgent, prompt: NetworkUserAgent.standard)
                Button("settings.use_shiroxs_own") { userAgent = NetworkUserAgent.standard }
                    .disabled(userAgent == NetworkUserAgent.standard)
            }
        } header: {
            Text("settings.user_agent")
        } footer: {
            Text(enabled ? String(localized: "settings.shiroxs_own \(NetworkUserAgent.standard)") : Self.note)
        }
    }

    private static let note = String(localized: "settings.the_browser_shirox_claims_to")
}

// MARK: - Test

private struct ConnectionTestSection: View {
    @State private var checks: [NetworkCheck] = []
    @State private var isTesting = false

    var body: some View {
        Section {
            Button(action: test) {
                HStack {
                    Text("settings.test_connection")
                    Spacer()
                    if isTesting { ProgressView() }
                }
            }
            .disabled(isTesting)
            ForEach(checks) { check in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    IconView(icon(for: check.outcome))
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
            Text("settings.checks_tmdbs_api_and_images")
        }
    }

    func test() {
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
                    Text(didReset ? String(localized: "settings.network_state_reset") : String(localized: "settings.reset_network_state"))
                    Spacer()
                    if isResetting { ProgressView() }
                }
            }
            .foregroundStyle(.red)
            .disabled(isResetting)
            .confirmationDialog("settings.reset_network_state_confirm", isPresented: $confirm, titleVisibility: .visible) {
                Button("common.reset", role: .destructive, action: reset)
                Button("common.cancel", role: .cancel) {}
            } message: {
                Text("settings.signs_shirox_out_of_websites")
            }
        } footer: {
            Text("settings.clears_cookies_website_data_the")
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
