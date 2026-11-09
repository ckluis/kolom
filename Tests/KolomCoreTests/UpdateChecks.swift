import CoreGraphics
import Foundation
import KolomCore

/// Release versions and update checks.
func updateChecks() throws {
    // Update check: GitHub's latest release against the running version.
    XCTAssertEqual(ReleaseVersion("v0.2.2")?.description, "0.2.2")
    XCTAssertTrue(ReleaseVersion("0.10.0")! > ReleaseVersion("0.9.9")!)
    XCTAssertTrue(ReleaseVersion("1.0.0")! > ReleaseVersion("0.99.99")!)
    XCTAssertFalse(ReleaseVersion("0.2.1")! > ReleaseVersion("0.2.1")!)
    for bad in ["development", "0.2", "0.2.1.4", "v0.+2.1", "0.2.-1", "0.2.1-beta", "", "0..1", "٠.٢.١"] {
        XCTAssertTrue(ReleaseVersion(bad) == nil)
    }
    func release(_ fields: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: fields) }
    let page = "https://github.com/ckluis/kolom/releases/tag/v0.2.2"
    XCTAssertEqual(
        UpdateCheck.update(fromLatestRelease: release(["tag_name": "v0.2.2", "html_url": page]), current: "0.2.1"),
        AvailableUpdate(version: "0.2.2", url: page))
    XCTAssertTrue(UpdateCheck.update(fromLatestRelease: release(["tag_name": "v0.2.1"]), current: "0.2.1") == nil)
    XCTAssertTrue(UpdateCheck.update(fromLatestRelease: release(["tag_name": "v0.2.0"]), current: "0.2.1") == nil)
    XCTAssertTrue(
        UpdateCheck.update(fromLatestRelease: release(["tag_name": "v0.3.0", "draft": true]), current: "0.2.1") == nil)
    XCTAssertTrue(
        UpdateCheck.update(fromLatestRelease: release(["tag_name": "v0.3.0", "prerelease": true]), current: "0.2.1")
            == nil)
    XCTAssertTrue(UpdateCheck.update(fromLatestRelease: release(["tag_name": "v0.3.0"]), current: "development") == nil)
    XCTAssertTrue(UpdateCheck.update(fromLatestRelease: Data("not json".utf8), current: "0.2.1") == nil)
    XCTAssertTrue(UpdateCheck.update(fromLatestRelease: release(["message": "Not Found"]), current: "0.2.1") == nil)
    // Only release pages of this repository are opened; anything else falls back to its releases.
    for foreign in ["https://evil.example/kolom", "https://github.com/ckluis/kolom-fake/releases/x", "javascript:alert(1)"] {
        XCTAssertEqual(
            UpdateCheck.update(fromLatestRelease: release(["tag_name": "v0.3.0", "html_url": foreign]), current: "0.2.1")?
                .url, UpdateCheck.releasesPage)
    }
    let remembered = AvailableUpdate(version: "0.2.2", url: page)
    XCTAssertEqual(UpdateCheck.stillNewer(remembered, current: "0.2.1"), remembered)
    XCTAssertTrue(UpdateCheck.stillNewer(remembered, current: "0.2.2") == nil)
    XCTAssertTrue(UpdateCheck.isDue(lastChecked: nil, now: 1000))
    XCTAssertFalse(UpdateCheck.isDue(lastChecked: 1000, now: 1000 + 23 * 3600))
    XCTAssertTrue(UpdateCheck.isDue(lastChecked: 1000, now: 1000 + 24 * 3600))
    XCTAssertTrue(UpdateCheck.isDue(lastChecked: 1000 + 3600, now: 1000))  // a clock set back
    XCTAssertEqual(
        UpdateCheck.command(checkout: "/Users/me/Kolom's code"),
        "cd '/Users/me/Kolom'\\''s code' && git pull --ff-only && ./scripts/install.sh --quit-running")
    XCTAssertEqual(UpdateCheck.command(checkout: nil), "git pull --ff-only && ./scripts/install.sh --quit-running")
    print("PASS: update checks compare release versions, ignore drafts and foreign pages, and quote the checkout")

}
