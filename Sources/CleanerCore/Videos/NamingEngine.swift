import Foundation

public enum NamingEngine {
    public static let defaultTemplate = "{yyyy}/{yyyy}-{MM}-{dd} {filename}"
    public static let tokens = ["{yyyy}", "{MM}", "{dd}", "{filename}", "{basename}", "{ext}"]

    public static func render(_ template: String, day: String, filename: String?) -> String {
        let file = clean(filename ?? "").replacingOccurrences(of: "/", with: "_")
        let name = file.isEmpty ? "video.mov" : file
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        let date = day.split(separator: "-").map(String.init)
        let values = [
            "{yyyy}": date.count == 3 ? date[0] : "0000",
            "{MM}": date.count == 3 ? date[1] : "00",
            "{dd}": date.count == 3 ? date[2] : "00",
            "{filename}": name,
            "{basename}": base,
            "{ext}": ext,
        ]
        var rendered = template
        for token in tokens { rendered = rendered.replacingOccurrences(of: token, with: values[token]!) }
        let components = rendered.split(separator: "/").map { clean(String($0)) }.filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        var path = components.isEmpty ? name : components.joined(separator: "/")
        if !ext.isEmpty, !path.lowercased().hasSuffix("." + ext.lowercased()) { path += "." + ext }
        return path
    }

    public static func edited(_ path: String) -> String {
        suffixed(path, " (edited)")
    }

    public static func numbered(_ path: String, _ number: Int) -> String {
        suffixed(path, " (\(number))")
    }

    private static func suffixed(_ path: String, _ suffix: String) -> String {
        let ext = (path as NSString).pathExtension
        guard !ext.isEmpty else { return path + suffix }
        return (path as NSString).deletingPathExtension + suffix + "." + ext
    }

    /// NFC because the exported files are read on Linux, where decomposed names don't match.
    private static func clean(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
