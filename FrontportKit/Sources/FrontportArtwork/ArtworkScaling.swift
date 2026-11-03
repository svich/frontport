import Foundation
import FrontportCore
import ImageIO
import UniformTypeIdentifiers

/// SteamGridDB's originals, up to 3840 pixels across, scaled down to the size Frontport shows them at before they're
/// cached: a 5 MB PNG hero becomes a few hundred KB of HEIC that decodes several times faster.
enum ArtworkScaling {
    struct Scaled {
        var data: Data
        var fileExtension: String
    }

    /// Nil when the image is no larger than `kind.maxPixels` or can't be read: then it's kept as it came.
    static func scaled(_ data: Data, kind: ArtworkKind) -> Scaled? {
        CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
            .flatMap { scaled($0, kind: kind) }
    }

    /// The same for a cached file; one already small enough is read no further than its header.
    static func scaled(contentsOf url: URL, kind: ArtworkKind) -> Scaled? {
        CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
            .flatMap { scaled($0, kind: kind) }
    }

    private static func scaled(_ source: CGImageSource, kind: ArtworkKind) -> Scaled? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            max(width, height) > kind.maxPixels
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: kind.maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // HEIC for opaque art; logos and icons keep their transparency as PNG.
        let isOpaque = [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let (type, fileExtension): (UTType, String) = isOpaque ? (.heic, "heic") : (.png, "png")
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return Scaled(data: output as Data, fileExtension: fileExtension)
    }
}
