import SwiftUI

struct JellyfinConnectView: View {
    @ObservedObject private var auth = JellyfinAuthManager.shared
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var error: String?
    @State private var showGuide = false

    private var fieldBackground: Color {
        #if os(iOS)
        Color(UIColor.systemBackground)
        #elseif os(macOS)
        Color(NSColor.windowBackgroundColor)
        #else
        Color.black
        #endif
    }

    var body: some View {
        VStack(spacing: 18) {
            IconView("server.rack")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("jellyfin.connect_to_jellyfin")
                .font(.headline)

            VStack(spacing: 10) {
                field(String(localized: "jellyfin.server_placeholder"), text: $server)
                field(String(localized: "settings.username"), text: $username)
                secureField(String(localized: "settings.password"), text: $password)
            }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Button {
                connect()
            } label: {
                HStack {
                    if isConnecting { ProgressView().scaleEffect(0.8) }
                    Text(isConnecting ? String(localized: "jellyfin.connecting") : String(localized: "jellyfin.connect")).font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.primary, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(fieldBackground)
            }
            .buttonStyle(.plain)
            .disabled(isConnecting || server.isEmpty || username.isEmpty)

            Button {
                showGuide = true
            } label: {
                Label("jellyfin.how_do_i_set_this", icon: "questionmark.circle")
                    .font(.subheadline)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(maxWidth: 460)
        .sheet(isPresented: $showGuide) {
            JellyfinSetupGuide()
                .macSheetFrame()
        }
    }

    private func field(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            #if !os(tvOS)
            .textFieldStyle(.roundedBorder)
            #endif
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
    }

    private func secureField(_ prompt: String, text: Binding<String>) -> some View {
        SecureField(prompt, text: text)
            #if !os(tvOS)
            .textFieldStyle(.roundedBorder)
            #endif
    }

    private func connect() {
        error = nil
        isConnecting = true
        Task {
            do {
                try await auth.authenticate(serverURL: server, username: username, password: password)
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isConnecting = false
        }
    }
}

/// A short walk-through for someone who has never run a Jellyfin server: what it is, how to
/// get one going, and what to type into the connect form.
private struct JellyfinSetupGuide: View {
    @Environment(\.dismiss) private var dismiss

    private struct Step: Identifiable {
        let id: Int
        let title: String
        let detail: String
    }

    #if os(macOS)
    private static let addressDetail = String(localized: "jellyfin.find_address_detail_mac")
    private static let connectDetail = String(localized: "jellyfin.connect_detail_mac")
    private static let openInSafari = String(localized: "jellyfin.open_in_safari_mac")
    #else
    private static let addressDetail = String(localized: "jellyfin.find_address_detail_phone")
    private static let connectDetail = String(localized: "jellyfin.connect_detail_phone")
    private static let openInSafari = String(localized: "jellyfin.open_in_safari_phone")
    #endif

    private let steps: [Step] = [
        Step(id: 1, title: String(localized: "jellyfin.install_jellyfin_on_a_computer"),
             detail: String(localized: "jellyfin.jellyfin_is_a_free_media")),
        Step(id: 2, title: String(localized: "jellyfin.add_your_library"),
             detail: String(localized: "jellyfin.in_the_jellyfin_dashboard_open")),
        Step(id: 3, title: String(localized: "jellyfin.find_the_server_address"),
             detail: Self.addressDetail),
        Step(id: 4, title: String(localized: "jellyfin.connect"),
             detail: Self.connectDetail),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(steps) { step in
                        HStack(alignment: .top, spacing: 14) {
                            Text("\(step.id)")
                                .font(.subheadline.weight(.bold))
                                .frame(width: 28, height: 28)
                                .background(Color.primary.opacity(0.1), in: Circle())
                            VStack(alignment: .leading, spacing: 4) {
                                Text(step.title).font(.headline)
                                Text(step.detail)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("jellyfin.if_it_wont_connect") {
                    Label("jellyfin.include_http_and_the_port", icon: "link")
                    #if os(iOS)
                    Label("jellyfin.allow_shirox_under_settings_privacy", icon: "wifi")
                    #endif
                    Label("jellyfin.make_sure_the_server_is", icon: "shield")
                    Label(Self.openInSafari, icon: "safari")
                }
                .font(.subheadline)

                Section {
                    Link(destination: URL(string: "https://jellyfin.org/docs/general/quick-start")!) {
                        Label("jellyfin.jellyfins_quick_start_guide", icon: "arrow.up.right.square")
                    }
                }
            }
            .navigationTitle("jellyfin.setting_up_jellyfin")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") { dismiss() }
                }
            }
        }
    }
}
