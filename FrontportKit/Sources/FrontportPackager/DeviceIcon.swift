import CoreGraphics
import Foundation
import FrontportCore
import ImageIO
import UniformTypeIdentifiers

/// Gives an app for Devices the Port's Catalog icon: Recipes and upstream ship an engine's logo, or none, and the home
/// screen shows the app's own icon, where the Mac app shows Catalog artwork. Loose PNGs at the sizes iPhone and iPad
/// show, named in `CFBundleIcons`, as no asset catalog is compiled; an asset catalog's icon (`CFBundleIconName`) is no
/// longer named, so iOS takes these.
enum DeviceIcon {
    /// Base name, point size and the scales of each icon file: `<name><size>x<size>@<scale>x[~ipad].png`.
    private static let name = "FrontportIcon"
    private static let iPhone: [(points: Double, scales: [Int])] = [(60, [2, 3])]
    private static let iPad: [(points: Double, scales: [Int])] = [(76, [2]), (83.5, [2])]

    /// Leaves the app as it was when `image` can't be read: the app keeps its own icon.
    static func replace(in app: URL, with image: URL) throws {
        guard let source = CGImageSourceCreateWithURL(image as CFURL, nil),
            let original = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return }
        var files: [(URL, Data)] = []
        for (idiom, sizes) in [("", iPhone), ("~ipad", iPad)] {
            for (points, scales) in sizes {
                for scale in scales {
                    let pixels = Int((points * Double(scale)).rounded())
                    guard let png = square(original, pixels: pixels) else { return }
                    files.append((try PortPackager.location("\(baseName(points))@\(scale)x\(idiom).png", in: app), png))
                }
            }
        }
        for (url, data) in files {
            // Written anew, never through what the app has at that name.
            try? FileManager.default.removeItem(at: url)
            do { try data.write(to: url, options: .withoutOverwriting) } catch {
                throw FrontportError.fileOperation("Couldn’t write \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        try setIcons(in: app)
    }

    private static func baseName(_ points: Double) -> String {
        let size = points.rounded() == points ? String(Int(points)) : String(points)
        return "\(name)\(size)x\(size)"
    }

    /// The image filling an opaque square, cropped to its middle: iOS shows a transparent icon's clear parts black.
    private static func square(_ image: CGImage, pixels: Int) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        let scale = Double(pixels) / Double(min(image.width, image.height))
        let (width, height) = (Double(image.width) * scale, Double(image.height) * scale)
        context.draw(
            image, in: CGRect(x: (Double(pixels) - width) / 2, y: (Double(pixels) - height) / 2, width: width, height: height))
        guard let square = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, square, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    private static func setIcons(in app: URL) throws {
        let url = try PortPackager.location("Info.plist", in: app)
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let data = try? Data(contentsOf: url),
            var info = try? PropertyListSerialization.propertyList(from: data, format: &format) as? [String: Any]
        else {
            throw FrontportError.signingFailed("\(app.lastPathComponent) has no readable Info.plist.")
        }
        let phone = iPhone.map { baseName($0.points) }
        let pad = phone + iPad.map { baseName($0.points) }
        info["CFBundleIcons"] = ["CFBundlePrimaryIcon": ["CFBundleIconFiles": phone]]
        info["CFBundleIcons~ipad"] = ["CFBundlePrimaryIcon": ["CFBundleIconFiles": pad]]
        for key in ["CFBundleIconName", "CFBundleIconFile", "CFBundleIconFiles"] { info[key] = nil }
        do {
            try PropertyListSerialization.data(fromPropertyList: info, format: format, options: 0).write(to: url, options: .atomic)
        } catch {
            throw FrontportError.signingFailed("Couldn’t write \(app.lastPathComponent)’s Info.plist: \(error.localizedDescription)")
        }
    }
}
