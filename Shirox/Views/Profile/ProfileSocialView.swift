import SwiftUI

struct ProfileSocialView: View {
    @ObservedObject var vm: ProfileViewModel
    let userId: Int
    var topContent: AnyView?

    @ObservedObject private var providerManager = ProviderManager.shared
    @State private var selectedSocial: ProfileViewModel.SocialType = .followers
    @State private var targetUserId: Int?
    @State private var targetUsername: String?

    private var isMAL: Bool { providerManager.primary?.providerType == .mal }

    var body: some View {
        let users = selectedSocial == .followers ? vm.followers : vm.following
        let hasNext = selectedSocial == .followers ? vm.hasNextFollowersPage : vm.hasNextFollowingPage

        List {
            if let topContent {
                topContent
                    .listRowInsets(EdgeInsets())
                    #if !os(tvOS)
                    .listRowSeparator(.hidden)
                    #endif
                    .listRowBackground(Color.clear)
            }

            if !isMAL {
                Picker("profile.social", selection: $selectedSocial) {
                    Text("profile.followers").tag(ProfileViewModel.SocialType.followers)
                    Text("common.following").tag(ProfileViewModel.SocialType.following)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 4)
                .padding(.vertical, 8)
                #if !os(tvOS)
                .listRowSeparator(.hidden)
                #endif
                .listRowBackground(Color.clear)
                .onChangeOf(selectedSocial) { newValue in
                    Task { await vm.loadSocial(userId: userId, type: newValue) }
                }
            }

            if vm.isLoadingSocial && users.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    #if !os(tvOS)
                    .listRowSeparator(.hidden)
                    #endif
                    .listRowBackground(Color.clear)
            } else if users.isEmpty {
                ContentUnavailableView {
                    Label("profile.no_users", icon: "person.2")
                } description: {
                    Text(isMAL ? String(localized: "profile.no_friends_yet") : (selectedSocial == .followers ? String(localized: "profile.no_followers_yet") : String(localized: "profile.not_following_anyone_yet")))
                }
                #if !os(tvOS)
                .listRowSeparator(.hidden)
                #endif
                .listRowBackground(Color.clear)
            } else {
                ForEach(users) { user in
                    Button {
                        guard !isMAL else { return }
                        targetUsername = user.name
                        targetUserId = user.id
                    } label: {
                        HStack(spacing: 12) {
                            CachedAsyncImage(urlString: user.avatarURL ?? "")
                                .frame(width: 44, height: 44)
                                .clipShape(Circle())
                            Text(user.name)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            if !isMAL {
                                IconView("chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isMAL)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }

                if hasNext {
                    Button {
                        Task { await vm.loadSocial(userId: userId, type: selectedSocial, loadMore: true) }
                    } label: {
                        HStack {
                            Spacer()
                            if vm.isLoadingSocial {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("profile.load_more").font(.subheadline.weight(.medium))
                            }
                            Spacer()
                        }
                    }
                    .padding(.vertical, 10)
                    .listRowBackground(Color.clear)
                }
            }
        }
        .softScrollEdges()
        .listStyle(.plain)
        .circleRefreshable { await vm.loadSocial(userId: userId, type: selectedSocial) }
        .task { await vm.loadSocial(userId: userId, type: selectedSocial) }
        .adaptiveSheet(item: $targetUserId) { uid in
            ProfileView(userId: uid, username: targetUsername ?? String(localized: "common.profile"), avatarURL: nil)
        }
    }
}
