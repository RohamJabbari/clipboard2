import Foundation
import Testing
@testable import Clipboard2

@MainActor
struct UpdateChecksTests {
    // MARK: Throttle

    @Test func throttleAllowsFirstCheckThenWaitsTwoMinutes() {
        var throttle = UpdateCheckThrottle()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        #expect(throttle.isDue(now: t0))
        throttle.record(now: t0)
        #expect(!throttle.isDue(now: t0))
        #expect(!throttle.isDue(now: t0.addingTimeInterval(119)))
        #expect(throttle.isDue(now: t0.addingTimeInterval(120)))
        throttle.record(now: t0.addingTimeInterval(130))
        #expect(!throttle.isDue(now: t0.addingTimeInterval(200)))
        #expect(throttle.isDue(now: t0.addingTimeInterval(250)))
    }

    // MARK: Indicator

    @Test func indicatorWalksNoneAvailableDownloadingReady() {
        let phases: [UpdateController.Phase] = [
            .idle, .checking, .upToDate,
            .available(version: "1.13.0", infoOnly: false),
            .downloading(fraction: nil), .downloading(fraction: 0.4), .preparing,
            .ready(version: "1.13.0"),
        ]
        #expect(phases.map(UpdateIndicator.init) == [
            .none, .none, .none,
            .available(version: "1.13.0"),
            .downloading, .downloading, .downloading,
            .ready(version: "1.13.0"),
        ])
        #expect(UpdateIndicator(.failed("offline")) == .none)
        #expect(UpdateIndicator(.installing) == .downloading)
    }

    @Test func probeAnnouncesOnlyFromQuietPhases() {
        let found = (version: "1.13.0", infoOnly: false)
        #expect(UpdateController.Phase.idle.afterProbe(found: found) == .available(version: "1.13.0", infoOnly: false))
        #expect(UpdateController.Phase.upToDate.afterProbe(found: found) == .available(version: "1.13.0", infoOnly: false))
        #expect(UpdateController.Phase.failed("x").afterProbe(found: nil) == .upToDate)
        #expect(UpdateController.Phase.idle.afterProbe(found: nil) == .upToDate)
        // A newer one replaces an older announcement; a pulled release clears it.
        #expect(UpdateController.Phase.available(version: "1.12.1", infoOnly: false).afterProbe(found: found)
                == .available(version: "1.13.0", infoOnly: false))
        #expect(UpdateController.Phase.available(version: "1.13.0", infoOnly: false).afterProbe(found: nil) == .upToDate)
        // Never over a download, a waiting restart or a running check.
        for phase: UpdateController.Phase in [.downloading(fraction: 0.5), .preparing, .ready(version: "1.13.0"), .installing, .checking] {
            #expect(phase.afterProbe(found: found) == phase)
            #expect(phase.afterProbe(found: nil) == phase)
        }
    }

    // MARK: Feed

    @Test func pinnedFeedReplacesBranchWithCommit() throws {
        let feed = try #require(PinnedFeed(URL(string: "https://raw.githubusercontent.com/RohamJabbari/clipboard2-macOS/main/appcast.xml")!))
        #expect(feed.owner == "RohamJabbari")
        #expect(feed.repo == "clipboard2-macOS")
        #expect(feed.branch == "main")
        #expect(feed.path == "appcast.xml")
        #expect(feed.headCommitURL.absoluteString == "https://api.github.com/repos/RohamJabbari/clipboard2-macOS/commits/main")
        let sha = "d3ff6f1b75441d2688b593489bb3210c58b19184"
        #expect(feed.url(at: sha).absoluteString
                == "https://raw.githubusercontent.com/RohamJabbari/clipboard2-macOS/\(sha)/appcast.xml")
    }

    @Test func pinnedFeedKeepsNestedPathsAndRejectsOtherHosts() {
        let nested = PinnedFeed(URL(string: "https://raw.githubusercontent.com/o/r/main/feeds/mac/appcast.xml")!)
        #expect(nested?.path == "feeds/mac/appcast.xml")
        #expect(PinnedFeed(URL(string: "https://example.com/o/r/main/appcast.xml")!) == nil)
        #expect(PinnedFeed(URL(string: "http://raw.githubusercontent.com/o/r/main/appcast.xml")!) == nil)
        #expect(PinnedFeed(URL(string: "https://raw.githubusercontent.com/o/r/appcast.xml")!) == nil)
    }

    @Test func onlyFullCommitHashesArePinned() {
        #expect(PinnedFeed.isSHA("d3ff6f1b75441d2688b593489bb3210c58b19184"))
        #expect(!PinnedFeed.isSHA("d3ff6f1"))
        #expect(!PinnedFeed.isSHA("{\"message\":\"API rate limit exceeded\"}"))
    }

    @Test func unresolvedFeedFallsBackToSparkleDefault() {
        #expect(FeedResolver(feedURL: URL(string: "https://raw.githubusercontent.com/o/r/main/appcast.xml")).feedURLString() == nil)
        #expect(FeedResolver(feedURL: nil).feedURLString() == nil)
    }
}
