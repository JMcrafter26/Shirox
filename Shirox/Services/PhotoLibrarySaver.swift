#if os(iOS)
import Photos
import UIKit

/// Saves images to Photos — into a "Shirox" album when the user granted full access, else
/// straight to the library (add-only or limited access can't create or fill albums).
enum PhotoLibrarySaver {
    enum Outcome {
        case savedToAlbum
        case savedToLibrary
        case denied
        case failed(Error)
    }

    private static let queue = DispatchQueue(label: "com.shirox.photoSaves")
    private static let albumTitle = "Shirox"

    /// `completion` runs on the main queue.
    static func save(_ image: UIImage, completion: @escaping (Outcome) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            queue.async {
                let outcome = save(image, status: status)
                DispatchQueue.main.async { completion(outcome) }
            }
        }
    }

    private static func save(_ image: UIImage, status: PHAuthorizationStatus) -> Outcome {
        let canUseAlbum = status == .authorized
        let canSave = canUseAlbum || status == .limited ||
            PHPhotoLibrary.authorizationStatus(for: .addOnly) == .authorized
        guard canSave else { return .denied }

        do {
            let album: PHAssetCollection? = canUseAlbum ? {
                let options = PHFetchOptions()
                options.predicate = NSPredicate(format: "title = %@", albumTitle)
                return PHAssetCollection.fetchAssetCollections(
                    with: .album, subtype: .albumRegular, options: options).firstObject
            }() : nil
            try PHPhotoLibrary.shared().performChangesAndWait {
                if canUseAlbum {
                    let albumRequest = album.flatMap { PHAssetCollectionChangeRequest(for: $0) }
                        ?? PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumTitle)
                    let asset = PHAssetChangeRequest.creationRequestForAsset(from: image)
                    if let placeholder = asset.placeholderForCreatedAsset {
                        albumRequest.addAssets([placeholder] as NSArray)
                    }
                } else {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }
            }
            return canUseAlbum ? .savedToAlbum : .savedToLibrary
        } catch {
            return .failed(error)
        }
    }
}
#endif
