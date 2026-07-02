import Foundation

/// A single find/replace rule. `find` is matched whole-word and
/// case-insensitively; `replace` is inserted literally (no backreference
/// expansion), mirroring the Python `(find, replace)` tuple pairs used by
/// `apply_replacements` in `textproc.py`.
public struct Replacement: Codable, Equatable, Sendable {
    public var find: String
    public var replace: String

    public init(find: String, replace: String) {
        self.find = find
        self.replace = replace
    }
}
