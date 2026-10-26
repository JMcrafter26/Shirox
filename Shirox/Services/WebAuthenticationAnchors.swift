#if !os(tvOS)
import AuthenticationServices

// Where each sign-in's web sheet is shown. The conformances live here because the managers
// can't take one only off tvOS, and SwiftLint wants no extensions of a type in its own file.

extension AniListAuthManager: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { presentationAnchorWindow ?? ASPresentationAnchor() }
    }
}

extension MALAuthManager: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { presentationAnchorWindow ?? ASPresentationAnchor() }
    }
}

extension SimklAuthManager: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { presentationAnchorWindow ?? ASPresentationAnchor() }
    }
}
#endif
