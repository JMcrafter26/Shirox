#if canImport(GoogleCast)
@preconcurrency import GoogleCast

// CastManager's GoogleCast listeners. They live in their own file because the class can't
// take a conformance only when GoogleCast is there, and SwiftLint wants no extensions of a
// type in its own file.

/// The full session lifecycle. Handling only `didStart` / `didEnd` / `didResume` — as this
/// did — left `isConnected` stuck true whenever a connection failed to establish or a
/// suspended one failed to come back, which is what forced an app restart mid-movie.
extension CastManager: GCKSessionManagerListener {
    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKCastSession) {
        MainActor.assumeIsolated { apply(.started) }
    }

    nonisolated func sessionManager(_ sessionManager: GCKSessionManager,
                                    didFailToStart session: GCKCastSession, withError error: Error) {
        MainActor.assumeIsolated { apply(.failedToStart, error: error) }
    }

    nonisolated func sessionManager(_ sessionManager: GCKSessionManager,
                                    didEnd session: GCKCastSession, withError error: Error?) {
        MainActor.assumeIsolated { apply(.ended, error: error) }
    }

    nonisolated func sessionManager(_ sessionManager: GCKSessionManager,
                                    didSuspend session: GCKCastSession, with reason: GCKConnectionSuspendReason) {
        MainActor.assumeIsolated { apply(.suspended) }
    }

    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didResumeCastSession session: GCKCastSession) {
        MainActor.assumeIsolated { apply(.resumed) }
    }

    /// The generic (non-cast) variants fire for the same transitions. A listener that takes
    /// only the cast-typed half misses any transition the SDK reports generically — and a
    /// missed "session ended" is precisely what left the app stuck on a dead cast screen.
    /// `CastSessionListenerSelectorTests` asserts every one of these is actually reachable
    /// from Objective-C, since an optional protocol member that fails to match just goes
    /// quiet rather than failing to build.
    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKSession) {
        MainActor.assumeIsolated { apply(.started) }
    }

    nonisolated func sessionManager(_ sessionManager: GCKSessionManager,
                                    didEnd session: GCKSession, withError error: Error?) {
        MainActor.assumeIsolated { apply(.ended, error: error) }
    }

    nonisolated func sessionManager(_ sessionManager: GCKSessionManager,
                                    didFailToStart session: GCKSession, withError error: Error) {
        MainActor.assumeIsolated { apply(.failedToStart, error: error) }
    }

    nonisolated func sessionManager(_ sessionManager: GCKSessionManager,
                                    didSuspend session: GCKSession, with reason: GCKConnectionSuspendReason) {
        MainActor.assumeIsolated { apply(.suspended) }
    }

    /// Selector pinned explicitly: Swift's importer does not give this one the name the
    /// pattern above would suggest, and an optional ObjC requirement that fails to match
    /// simply never fires — silently, with no build error. That is the whole failure mode
    /// this class of bug lives in.
    @objc(sessionManager:didResumeSession:)
    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didResumeSession session: GCKSession) {
        MainActor.assumeIsolated { apply(.resumed) }
    }
}

extension CastManager: GCKRemoteMediaClientListener {
    nonisolated func remoteMediaClient(_ client: GCKRemoteMediaClient, didUpdate mediaStatus: GCKMediaStatus?) {
        // GCKMediaStatus is an immutable snapshot; wrap it so the region-isolation
        // checker allows the send across the actor boundary.
        struct StatusBox: @unchecked Sendable { let value: GCKMediaStatus? }
        let box = StatusBox(value: mediaStatus)
        Task { @MainActor in self.updateMediaStatus(box.value) }
    }

    /// The receiver dropped the media entirely (an app crash on the TV, someone casting
    /// something else to it). Without this the app kept showing a live scrubber.
    nonisolated func remoteMediaClientDidUpdateQueue(_ client: GCKRemoteMediaClient) {
        Task { @MainActor in self.updateMediaStatus(client.mediaStatus) }
    }
}

extension CastManager: GCKRequestDelegate {
    nonisolated func request(_ request: GCKRequest, didFailWithError error: GCKError) {
        Logger.shared.log("[Cast] Request failed: \(error.localizedDescription)", type: "Error")
        // A load that fails leaves the TV on its idle screen; say so instead of presenting
        // a cast overlay for media that never started.
        Task { @MainActor in self.lastError = error.localizedDescription }
    }
}
#endif
