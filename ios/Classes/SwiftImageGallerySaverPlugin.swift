import Flutter
import Photos

/// Saves images/videos to the user's Photos library via `PHAssetCreationRequest`,
/// which streams files from disk without decoding them (the source format and
/// metadata reach the library untouched).
///
/// Contract: every call replies exactly once, on the main thread, with
/// `{isSuccess, filePath?, errorMessage?}`. Failures carry the Photos error
/// text verbatim (e.g. `PHPhotosErrorDomain Code=3311` for a permission
/// denial) — Dart callers parse that text to classify the failure.
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
            // The `quality` argument is accepted but deliberately ignored:
            // bytes are ingested as-is, never re-encoded.
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
    /// thread. `performChanges` presents the add-to-library permission prompt
    /// itself when access is undetermined; a denial arrives as a
    /// `PHPhotosErrorDomain` error in the completion.
    ///
    /// `isReturnImagePathOfIOS`/`isReturnPathOfIOS` are accepted for API
    /// compatibility, but on success `filePath` is always the source path.
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

    /// Extensions routed as videos; everything else is ingested as a photo.
    /// Formats Photos can't ingest (webm/mkv/avi…) fail through the
    /// completion with a real error, which callers use to fall back.
    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "3gp", "3gpp", "mpg", "mpeg", "webm", "mkv", "avi",
    ]

    private static func isVideoFile(_ path: String) -> Bool {
        videoExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// `{isSuccess: Bool, filePath: String?, errorMessage: String?}` —
    /// nil values omit the key, which Dart map lookups read as null.
    private static func resultMap(isSuccess: Bool, filePath: String? = nil, error: String? = nil) -> [String: Any] {
        var map: [String: Any] = ["isSuccess": isSuccess]
        map["filePath"] = filePath
        map["errorMessage"] = error
        return map
    }
}
