import Foundation

/// Case-insensitive path comparison helpers (`~/dev` and `~/Dev` are the same folder).
public enum PathRules {
    /// Expands a leading `~`, standardises (`.`, `..`, trailing `/`) and lowercases.
    public static func normalize(_ path: String, home: String) -> String {
        standardized(path, home: home).lowercased()
    }

    /// Expands a leading `~` and standardises (`.`, `..`, trailing `/`); the case is kept.
    static func standardized(_ path: String, home: String) -> String {
        var p = path
        if p == "~" {
            p = home
        } else if p.hasPrefix("~/") {
            p = home + "/" + p.dropFirst(2)
        }
        var s = (p as NSString).standardizingPath
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// True when `path` equals `prefix` or lies below it. Whole components only.
    public static func isUnder(_ path: String, prefix: String, home: String) -> Bool {
        let p = normalize(path, home: home)
        let base = normalize(prefix, home: home)
        if p == base { return true }
        let withSlash = base.hasSuffix("/") ? base : base + "/"
        return p.hasPrefix(withSlash)
    }
}
