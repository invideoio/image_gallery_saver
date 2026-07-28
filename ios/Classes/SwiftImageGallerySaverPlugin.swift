import Flutter
import UIKit
import Photos

/// Saves images/videos to the user's Photos library.
///
/// Rewritten (2026-07) to fix reliability issues in the original implementation:
/// - The `FlutterResult` is captured per call. The old shared `var result`
///   property dropped one reply when two saves overlapped (leaving that Dart
///   `await` stuck forever) and could invoke the surviving reply twice.
/// - Every code path replies exactly once. The old `guard … else { return }`
///   and nil-image paths returned without replying, permanently hanging the
///   caller.
/// - Files are ingested via `PHAssetCreationRequest.addResource(fileURL:)`,
///   which streams from disk. The old `UIImage(contentsOfFile:)` decoded the
///   entire image into memory (an 8K PNG ≈ 250 MB → jetsam risk on low-RAM
///   devices), re-encoded it, and thereby stripped the original format,
///   metadata, and GIF animation.
/// - Photos errors are passed through verbatim (e.g. `PHPhotosErrorDomain
///   Code=3311`) instead of a generic message whose "permission" wording made
///   callers misclassify every failure as a permission denial.
public class SwiftImageGallerySaverPlugin: NSObject, FlutterPlugin {

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "image_gallery_saver", binaryMessenger: registrar.messenger())
        let instance = SwiftImageGallerySaverPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "saveImageToGallery":
            guard let arguments = call.arguments as? [String: Any],
                  let imageData = (arguments["imageBytes"] as? FlutterStandardTypedData)?.data,
                  !imageData.isEmpty else {
                result(Self.resultMap(isSuccess: false, error: "parameters error: imageBytes is required"))
                return
            }
            // Bytes are ingested as-is — no decode/re-encode, so the original
            // format is preserved. The legacy `quality` argument only ever
            // applied to the old lossy JPEG round-trip and is now ignored.
            performSave({ creation in
                creation.addResource(with: .photo, data: imageData, options: nil)
            }, filePath: nil, completion: result)

        case "saveFileToGallery":
            guard let arguments = call.arguments as? [String: Any],
                  let path = arguments["file"] as? String, !path.isEmpty else {
                result(Self.resultMap(isSuccess: false, error: "parameters error: file is required"))
                return
            }
            guard FileManager.default.fileExists(atPath: path) else {
                result(Self.resultMap(isSuccess: false, error: "file does not exist: \(path)"))
                return
            }
            let type: PHAssetResourceType = Self.isVideoFile(path) ? .video : .photo
            let url = URL(fileURLWithPath: path)
            performSave({ creation in
                creation.addResource(with: type, fileURL: url, options: nil)
            }, filePath: path, completion: result)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Runs one Photos change request and replies exactly once, on the main
    /// thread. `performChanges` triggers the add-to-library permission prompt
    /// itself when access is not yet determined; a denial surfaces as a
    /// `PHPhotosErrorDomain` error in the completion rather than a crash.
    ///
    /// `isReturnImagePathOfIOS`/`isReturnPathOfIOS` are still accepted for API
    /// compatibility, but `filePath` is now always the source path on success —
    /// the old Photos-library URL lookup tripled the code for a value no
    /// caller reads (callers only check `isSuccess`).
    private func performSave(
        _ addResource: @escaping (PHAssetCreationRequest) -> Void,
        filePath: String?,
        completion: @escaping FlutterResult
    ) {
        PHPhotoLibrary.shared().performChanges({
            addResource(PHAssetCreationRequest.forAsset())
        }) { success, error in
            DispatchQueue.main.async {
                if success {
                    completion(Self.resultMap(isSuccess: true, filePath: filePath))
                } else {
                    let message = error.map { String(describing: $0) } ?? "Photos returned no error details"
                    completion(Self.resultMap(isSuccess: false, error: message))
                }
            }
        }
    }

    /// Extensions routed as videos; everything else is ingested as a photo
    /// (Photos accepts webp/heif/bmp/tiff this way — the old allowlist pushed
    /// them into the video branch, which always failed). Containers Photos
    /// can't ingest (webm/mkv/avi…) fail with a real error, which callers
    /// recover from via their share-sheet fallback.
    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "3gp", "3gpp", "mpg", "mpeg", "webm", "mkv", "avi",
    ]

    private static func isVideoFile(_ path: String) -> Bool {
        videoExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// Same shape the Dart side has always consumed:
    /// `{isSuccess: Bool, filePath: String?, errorMessage: String?}`.
    /// nil values omit the key, which Dart map lookups read as null.
    private static func resultMap(isSuccess: Bool, filePath: String? = nil, error: String? = nil) -> [String: Any] {
        var map: [String: Any] = ["isSuccess": isSuccess]
        map["filePath"] = filePath
        map["errorMessage"] = error
        return map
    }
}
