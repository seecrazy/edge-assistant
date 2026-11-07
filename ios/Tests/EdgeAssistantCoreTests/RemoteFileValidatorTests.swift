import XCTest
@testable import EdgeAssistantCore

final class RemoteFileValidatorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-file-validator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ name: String, _ data: Data) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testRejectsEmptyAndHTMLJSON() throws {
        let empty = try write("empty.json", Data())
        let html = try write("bad.json", Data("<html>oops</html>".utf8))

        XCTAssertThrowsError(try RemoteFileValidator.validateFile(at: empty, relativePath: "empty.json"))
        XCTAssertThrowsError(try RemoteFileValidator.validateFile(at: html, relativePath: "bad.json"))
    }

    func testAcceptsValidSafetensorsHeader() throws {
        let headerData = Data(#"{"weight":{"dtype":"F16","shape":[2],"data_offsets":[0,4]}}"#.utf8)
        let weights = withUnsafeBytes(of: UInt64(headerData.count).littleEndian) { Data($0) }
            + headerData + Data([1, 2, 3, 4])
        let url = try write("model.safetensors", weights)

        try RemoteFileValidator.validateFile(at: url, relativePath: "model.safetensors")
    }

    func testAcceptsScalarSafetensorsWithEmptyShape() throws {
        let headerData = Data(#"{"scale":{"dtype":"BF16","shape":[],"data_offsets":[0,2]}}"#.utf8)
        let weights = withUnsafeBytes(of: UInt64(headerData.count).littleEndian) { Data($0) }
            + headerData + Data([1, 2])
        let url = try write("model.safetensors", weights)

        try RemoteFileValidator.validateFile(at: url, relativePath: "model.safetensors")
    }

    func testRejectsTruncatedSafetensors() throws {
        let headerData = Data(#"{"weight":{"dtype":"F16","shape":[2],"data_offsets":[0,8]}}"#.utf8)
        let weights = withUnsafeBytes(of: UInt64(headerData.count).littleEndian) { Data($0) }
            + headerData + Data([1, 2, 3])
        let url = try write("truncated.safetensors", weights)

        XCTAssertThrowsError(try RemoteFileValidator.validateFile(at: url, relativePath: "truncated.safetensors"))
    }

    func testRejectsModelDirectoryWithBadTokenizer() throws {
        try Data(#"{"model":"qwen"}"#.utf8).write(to: directory.appendingPathComponent("config.json"))
        try Data("<html>tokenizer</html>".utf8).write(to: directory.appendingPathComponent("tokenizer.json"))
        let headerData = Data(#"{"weight":{"dtype":"F16","shape":[1],"data_offsets":[0,1]}}"#.utf8)
        try (withUnsafeBytes(of: UInt64(headerData.count).littleEndian) { Data($0) } + headerData + Data([1]))
            .write(to: directory.appendingPathComponent("model.safetensors"))

        XCTAssertThrowsError(try RemoteFileValidator.validateModelDirectory(at: directory))
    }
}
