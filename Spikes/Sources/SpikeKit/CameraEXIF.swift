import Foundation
import ImageIO

public enum CameraEXIF {
    public static func makeAndModel(_ properties: [String: Any]) -> (make: String?, model: String?) {
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        func clean(_ key: CFString) -> String? {
            let value = (tiff?[key as String] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        return (clean(kCGImagePropertyTIFFMake), clean(kCGImagePropertyTIFFModel))
    }

    public static func isCamera(_ properties: [String: Any]) -> Bool {
        let tags = makeAndModel(properties)
        return tags.make != nil || tags.model != nil
    }
}
