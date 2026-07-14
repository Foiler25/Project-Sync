import XCTest
@testable import ProjectSync

final class ExclusionPresetTests: XCTestCase {
    func testDeveloperPresetCoversCommonBuildArtifactsAcrossSubfolders() {
        let patterns = Set(ExclusionPresets.developerProjects)

        for expected in [
            "node_modules/", ".build/", "DerivedData/", "__pycache__/", "target/", ".pio/",
            ".gradle/", "build/", "bin/", "obj/", "CMakeFiles/", ".dart_tool/"
        ] {
            XCTAssertTrue(patterns.contains(expected), "Missing developer exclusion: \(expected)")
        }
    }

    func testDeveloperPresetKeepsRepositoryHistoryAndSecretsByDefault() {
        let patterns = Set(ExclusionPresets.developerProjects)

        XCTAssertFalse(patterns.contains(".git/"))
        XCTAssertFalse(patterns.contains(".env"))
        XCTAssertTrue(ExclusionPresets.sourceControlMetadata.contains(".git/"))
        XCTAssertTrue(ExclusionPresets.localSecrets.contains(".env"))
    }

    func testDeveloperPresetDoesNotContainDuplicates() {
        XCTAssertEqual(
            ExclusionPresets.developerProjects.count,
            Set(ExclusionPresets.developerProjects).count
        )
    }
}
