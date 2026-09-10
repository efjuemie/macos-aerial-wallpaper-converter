import Foundation

@main
enum EncoderIntegrityTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wallpaper-converter-encoder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let resources = directory.appendingPathComponent("Resources", isDirectory: true)
        let binary = EncoderAssetSelector.binaryURL(resourcesRoot: resources)
        let manifestURL = EncoderAssetSelector.manifestURL(resourcesRoot: resources)
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        let originalBinary = Data("fake arm64 encoder".utf8)
        try originalBinary.write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let hash = try EncoderAssetValidator.sha256(binary)
        let manifest = EncoderAssetManifest(
            version: 1,
            architecture: "arm64",
            files: [EncoderAssetSelector.binaryRelativePath: hash]
        )
        let data = try JSONEncoder().encode(manifest)
        try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: manifestURL)

        let selected = EncoderAssetSelector.binaryURL(resourcesRoot: resources)
        require(selected == binary, "bundled encoder selector must choose Resources/Encoder/bin")
        require(
            (try? EncoderAssetValidator.validate(binaryURL: binary, manifestURL: manifestURL, actualArchitecture: "arm64")) != nil,
            "valid bundled encoder must pass integrity checks"
        )
        require(
            throws: { try EncoderAssetValidator.validate(binaryURL: binary, manifestURL: manifestURL, actualArchitecture: "x86_64") },
            "architecture mismatch must fail"
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: binary.path)
        require(
            throws: { try EncoderAssetValidator.validate(binaryURL: binary, manifestURL: manifestURL, actualArchitecture: "arm64") },
            "non-executable encoder must fail"
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        try FileManager.default.removeItem(at: binary)
        require(
            throws: { try EncoderAssetValidator.validate(binaryURL: binary, manifestURL: manifestURL, actualArchitecture: "arm64") },
            "missing encoder must fail"
        )
        try originalBinary.write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        try Data("corrupted".utf8).write(to: binary)
        require(
            throws: { try EncoderAssetValidator.validate(binaryURL: binary, manifestURL: manifestURL, actualArchitecture: "arm64") },
            "hash mismatch must fail"
        )
        print("PASS: bundled encoder integrity")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fail(message) }
    }

    private static func require(throws operation: () throws -> Any, _ message: String) {
        do {
            _ = try operation()
            fail(message)
        } catch { }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!)
        exit(1)
    }
}
