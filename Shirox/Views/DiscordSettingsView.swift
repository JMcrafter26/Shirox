#if !os(tvOS)
import SwiftUI

/// Discord Rich Presence: on or off, the Discord account, and what the status shows.
struct DiscordSettingsView: View {
    @ObservedObject private var discord = DiscordPresence.shared
    @AppStorage(DiscordPresence.enabledKey) private var enabled = false
    @AppStorage(DiscordPresence.applicationIDKey) private var applicationID = DiscordPresence.defaultApplicationID
    @AppStorage(DiscordPresence.showsCoverKey) private var showsCover = true
    @AppStorage(DiscordPresence.showsDetailsKey) private var showsDetails = true

    var body: some View {
        SettingsList {
            Section {
                Toggle("settings.discord_rich_presence", isOn: $enabled)
                    .switchTint()
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("settings.discord_rich_presence_note")
                    Text("settings.discord_account_disclaimer")
                }
            }

            if enabled {
                Section {
                    if discord.isSignedIn {
                        LabeledContent("settings.discord_account") {
                            Text(discord.username ?? String(localized: "settings.signed_in"))
                                .foregroundStyle(.secondary)
                        }
                        Button(LocalizedStringKey(discord.isShowingTest ? "settings.discord_clear_test" : "settings.discord_send_test")) {
                            if discord.isShowingTest { discord.clear() } else { discord.showTest() }
                        }
                        Button("settings.sign_out", role: .destructive) { discord.signOut() }
                    } else {
                        Button {
                            if let anchor = keyPresentationAnchor() {
                                discord.signIn(presentationAnchor: anchor)
                            }
                        } label: {
                            HStack {
                                Text("settings.discord_sign_in")
                                if discord.isSigningIn { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(discord.isSigningIn)
                    }
                    if let error = discord.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("settings.discord_account")
                } footer: {
                    Text("settings.discord_sign_in_note")
                }

                Section {
                    Toggle("settings.discord_show_cover", isOn: $showsCover)
                        .switchTint()
                    Toggle("settings.discord_show_details", isOn: $showsDetails)
                        .switchTint()
                } header: {
                    Text("settings.discord_shown")
                } footer: {
                    Text("settings.discord_shown_note")
                }

                Section {
                    TextField("settings.discord_application_id", text: $applicationID)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                        .autocorrectionDisabled()
                } header: {
                    Text("settings.discord_application_id")
                } footer: {
                    Text("settings.discord_application_id_note")
                }
            }
        }
        .softScrollEdges()
        .navigationTitle("settings.discord")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onChangeOf(enabled) { on in
            if !on { discord.clear() }
        }
    }
}
#endif
