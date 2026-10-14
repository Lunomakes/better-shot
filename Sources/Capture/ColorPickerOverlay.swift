import AppKit

@MainActor
final class ColorPickerOverlay {
    enum PickError: LocalizedError {
        case unsupportedColor

        var errorDescription: String? {
            "This color couldn’t be converted to RGB. Try picking another pixel."
        }
    }

    /// An sRGB color as 0-255 channels.
    struct Components: Equatable {
        let red: Int
        let green: Int
        let blue: Int
    }

    enum Format: String, CaseIterable {
        case hex
        case rgb

        static let storageKey = "bs_colorPickerFormat"

        static var current: Format {
            UserDefaults.standard.string(forKey: storageKey).flatMap(Format.init(rawValue:)) ?? .hex
        }

        var title: String {
            switch self {
            case .hex: "HEX"
            case .rgb: "RGB"
            }
        }

        func string(_ c: Components) -> String {
            switch self {
            case .hex: String(format: "#%02X%02X%02X", c.red, c.green, c.blue)
            case .rgb: "rgb(\(c.red), \(c.green), \(c.blue))"
            }
        }
    }

    func pickColor() async throws -> Components? {
        let sampler = NSColorSampler()
        let color = await withCheckedContinuation { (cont: CheckedContinuation<NSColor?, Never>) in
            sampler.show { selectedColor in
                cont.resume(returning: selectedColor)
            }
        }
        // AppKit completes asynchronously; retain the sampler until it calls back.
        return try withExtendedLifetime(sampler) {
            guard let color else { return nil }
            return try Self.components(of: color)
        }
    }

    static func components(of color: NSColor) throws -> Components {
        guard let rgb = color.usingColorSpace(.sRGB) else { throw PickError.unsupportedColor }
        let channels = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
        guard channels.allSatisfy(\.isFinite) else { throw PickError.unsupportedColor }
        let bytes = channels.map { Int((min(max($0, 0), 1) * 255).rounded()) }
        return Components(red: bytes[0], green: bytes[1], blue: bytes[2])
    }

    static func hexFromColor(_ color: NSColor) throws -> String {
        Format.hex.string(try components(of: color))
    }
}
