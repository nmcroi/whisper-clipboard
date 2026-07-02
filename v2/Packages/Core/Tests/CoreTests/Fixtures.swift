import Foundation

enum Fixtures {
    enum FixtureError: Error {
        case notFound(String)
    }

    /// Locates a file under the bundled `Fixtures/golden/` test resources.
    static func golden(_ name: String) throws -> URL {
        guard
            let url = Bundle.module.url(
                forResource: name,
                withExtension: nil,
                subdirectory: "Fixtures/golden"
            )
        else {
            throw FixtureError.notFound(name)
        }
        return url
    }
}
