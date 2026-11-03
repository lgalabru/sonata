import AppKit
import ImageIO
import SonataCore
import SwiftUI

/// Validators' published icons: fetched on demand, shrunk to a small square
/// thumbnail, and kept on disk so each is downloaded once.
@MainActor
@Observable
final class IconStore {
    static let shared = IconStore()

    /// Loaded thumbnails by identity. Reading it subscribes a view to that icon arriving.
    private(set) var images: [String: NSImage] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    /// Icons that failed: not retried until this long has passed.
    @ObservationIgnored private var failed: [String: Date] = [:]
    @ObservationIgnored private let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("sonata/icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    nonisolated static let pixels = 96
    nonisolated static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: config)
    }()

    func image(_ identity: String) -> NSImage? { images[identity] }

    /// Starts loading `identity`'s icon if it has one and it isn't loaded.
    func request(_ identity: String, url: URL?) {
        guard let url, images[identity] == nil, !inFlight.contains(identity) else { return }
        if let at = failed[identity], Date().timeIntervalSince(at) < 3_600 { return }
        let file = directory.appendingPathComponent(Self.fileName(identity, url))
        if let image = NSImage(contentsOf: file) {
            images[identity] = image
            return
        }
        inFlight.insert(identity)
        Task {
            let thumbnail = await Self.fetchThumbnail(url)
            inFlight.remove(identity)
            guard let thumbnail else {
                failed[identity] = Date()
                return
            }
            try? thumbnail.png.write(to: file, options: .atomic)
            images[identity] = thumbnail.image
        }
    }

    /// The URL is part of the name, so a validator changing its icon fetches the new one.
    static func fileName(_ identity: String, _ url: URL) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in url.absoluteString.utf8 { hash = (hash ^ UInt64(b)) &* 0x100_0000_01b3 }
        return "\(identity.prefix(16))-\(String(hash, radix: 36)).png"
    }

    /// Downloads and decodes off the main actor. Plain-HTTP icons are tried over HTTPS
    /// (App Transport Security would refuse them anyway).
    nonisolated static func fetchThumbnail(_ url: URL) async -> (image: NSImage, png: Data)? {
        var url = url
        if url.scheme == "http", var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            c.scheme = "https"
            url = c.url ?? url
        }
        guard url.scheme == "https",
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              data.count < 8_000_000
        else { return nil }
        return thumbnail(data)
    }

    /// A centered square crop scaled to `pixels`, as PNG. ImageIO handles PNG, JPEG, GIF, WebP
    /// and HEIC; anything else (SVG) falls back to NSImage.
    nonisolated static func thumbnail(_ data: Data) -> (image: NSImage, png: Data)? {
        var cg: CGImage?
        if let source = CGImageSourceCreateWithData(data as CFData, nil) {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceThumbnailMaxPixelSize: pixels * 2,
                                            kCGImageSourceCreateThumbnailWithTransform: true]
            cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        if cg == nil, let ns = NSImage(data: data) {
            var rect = CGRect(origin: .zero, size: CGSize(width: pixels * 2, height: pixels * 2))
            cg = ns.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        guard let cg, cg.width > 0, cg.height > 0 else { return nil }
        let side = min(cg.width, cg.height)
        let crop = cg.cropping(to: CGRect(x: (cg.width - side) / 2, y: (cg.height - side) / 2, width: side, height: side)) ?? cg
        guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        guard let out = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: out)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return (NSImage(cgImage: out, size: NSSize(width: pixels / 2, height: pixels / 2)), png)
    }
}

/// A validator's icon, or its monogram while there's none.
struct ValidatorAvatar: View {
    let model: SonataModel
    let identity: String
    var size: Double = 34
    /// Squircle, as the cards' tiles; or a circle, as on the map.
    var circle = false

    var body: some View {
        let store = IconStore.shared
        let shape = AnyShape(circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: size * 12 / 44, style: .continuous)))
        Group {
            if let image = store.image(identity) {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                Monogram(name: model.pin(identity).displayName, seed: identity, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
        .onAppear { store.request(identity, url: model.iconURL(identity)) }
        .onChange(of: identity) { _, id in store.request(id, url: model.iconURL(id)) }
        .accessibilityHidden(true)
    }
}

/// The first letters of a name on a color picked from the identity.
private struct Monogram: View {
    var name: String
    var seed: String
    var size: Double

    var body: some View {
        let letters = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(2).compactMap(\.first).map(String.init).joined()
        ZStack {
            LinearGradient(colors: [color.opacity(0.9), color.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(letters.isEmpty ? "◎" : letters.uppercased())
                .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.5)
        }
    }

    private var color: Color {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in seed.utf8 { hash = (hash ^ UInt64(b)) &* 0x100_0000_01b3 }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.45, brightness: 0.62)
    }
}
