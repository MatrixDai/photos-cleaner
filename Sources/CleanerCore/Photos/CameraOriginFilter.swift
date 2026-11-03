import Foundation
import ImageIO

public struct CameraTags: Equatable, Sendable {
    public var make: String?
    public var model: String?

    public init(make: String?, model: String?) {
        self.make = make
        self.model = model
    }

    public init(properties: [String: Any]) {
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        func clean(_ key: CFString) -> String? {
            let value = (tiff?[key as String] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        self.init(make: clean(kCGImagePropertyTIFFMake), model: clean(kCGImagePropertyTIFFModel))
    }

    public var isCamera: Bool { make != nil || model != nil }
}

public protocol PhotoAnalyzing: Sendable {
    func cameraTags(_ photoID: String) async throws -> CameraTags
    func aestheticsScore(_ photoID: String) async throws -> Double
}
