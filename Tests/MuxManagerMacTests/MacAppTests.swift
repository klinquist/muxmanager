#if os(macOS)
import XCTest
import AppKit
@testable import Mux_Manager

final class MacAppTests: XCTestCase {
    @MainActor
    func testNativeControlsAndRendering() async throws {
        XCTAssertEqual(LibraryStore.screenshotScene, "mac-tests", "Tests must use fictional data without Keychain/CloudKit/SSH")
        let model = AppModel(library: LibraryStore())
        // Let SwiftUI mount the native window before checking the rendered view.
        try await Task.sleep(for: .seconds(2))
        let checks = await MacValidation.run(model: model)
        for (name, passed) in checks.sorted(by: { $0.key < $1.key }) {
            XCTAssertTrue(passed, name)
        }
        if let view = NSApp.windows.first(where: { $0.isVisible })?.contentView,
           let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let image = NSImage(size: view.bounds.size)
            image.addRepresentation(bitmap)
            let attachment = XCTAttachment(image: image)
            attachment.name = "Mux Manager native Mac window"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor
    func testAutomaticReconnectOnMac() async throws {
        let model = AppModel(library: LibraryStore())
        let workspace = try XCTUnwrap(model.activeWorkspace)
        await workspace.validateAutomaticReconnect()
        let data = try Data(contentsOf: FileManager.default.temporaryDirectory.appendingPathComponent("mux-reconnect-report.json"))
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(report["passed"] as? Bool, true, "\(report)")
    }
}
#endif
