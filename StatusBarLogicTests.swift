import Foundation

@main
private enum StatusBarLogicTests {
    static func main() {
        aggregationAndAlertTests()
        displayAndPaceTests()
        versionTests()
        accountListTests()
        assert(sessionMenuLabel(authenticated: false, role: "admin") == nil)
        assert(sessionMenuLabel(authenticated: true, role: "admin") == "Signed in as Admin")
        assert(sessionMenuLabel(authenticated: true, role: "guest") == "Signed in as Guest")
        assert(sessionMenuLabel(authenticated: true, role: nil) == "Signed in")
        assert(UsageChartStyle(rawValue: "line") == .line)
        assert(abs(surfaceIntensity(brightness: 0.5) - 1) < 0.0001)
        assert(abs(surfaceIntensity(brightness: 0) - 0.4) < 0.0001)
        assert(abs(surfaceIntensity(brightness: 1) - 2.2) < 0.0001)
        assert(abs(surfaceIntensity(brightness: 7) - 2.2) < 0.0001)
        assert(surfaceIntensity(brightness: 0.25) < 1 && surfaceIntensity(brightness: 0.75) > 1)
        assert(quotaTone(for: 70) == .green)
        assert(quotaTone(for: 69.9) == .amber)
        assert(quotaTone(for: 30) == .amber)
        assert(quotaTone(for: 29.9) == .red)

        let now = Date(timeIntervalSince1970: 0)
        let eightDays = now.addingTimeInterval(8 * 86_400)
        assert(compactResetCreditLabel(count: 2, expiresAt: eightDays, now: now) == "Reset 2 / 8d")
        assert(compactResetCreditLabel(count: 0, expiresAt: eightDays, now: now) == nil)
        assert(compactResetCreditLabel(count: 3, expiresAt: nil, now: now) == "Reset 3")
        assert(elapsedTime(since: now.addingTimeInterval(-(86_400 + 3_600)), now: now) == "1d 1h")
        assert(elapsedTime(since: now.addingTimeInterval(-3_600), now: now) == "1h 0m")

        assert(refreshStatusLabel(isRefreshing: true, lastRefreshedAt: nil) == "Refreshing...")
        assert(refreshStatusLabel(isRefreshing: false, lastRefreshedAt: nil) == nil)
        assert(refreshStatusLabel(isRefreshing: false, lastRefreshedAt: now)?.hasPrefix("Updated ") == true)
        assert(codexLBVersionLabel("1.21.0-beta.3") == "Codex LB 1.21.0-beta.3")
        assert(codexLBVersionLabel("  ") == "Codex LB version unavailable")

        assert(averageRemaining([90, 95, 94]) == 93)
        assert(averageRemaining([nil, 50]) == 50)
        assert(averageRemaining([nil, nil]) == nil)
        assert(quotaSummaryTitle(primary: 93, secondary: 7, monthly: nil, activeCount: 3, totalCount: 3) == "5h 93% W 7% (3/3)")

        let burnFirst = routingBadgePresentation("burn_first")
        assert(burnFirst.label == "Burn first")
        assert(burnFirst.tone == .burnFirst)
        assert(burnFirst.symbolName == "flame.fill")

        let preserve = routingBadgePresentation("preserve")
        assert(preserve.label == "Preserve")
        assert(preserve.tone == .preserve)
        assert(preserve.symbolName == "shield")

        let normal = routingBadgePresentation("normal")
        assert(normal.label == "Normal")
        assert(normal.tone == .neutral)
        assert(normal.symbolName == nil)

        let active = accountStatusPresentation("active")
        assert(active.label == "Active")
        assert(active.tone == .green)
        assert(active.canToggle)

        let paused = accountStatusPresentation("paused")
        assert(paused.tone == .amber)
        assert(paused.canToggle)

        let rateLimited = accountStatusPresentation("rate_limited")
        assert(rateLimited.tone == .amber)
        assert(!rateLimited.canToggle)

        let quotaExceeded = accountStatusPresentation("quota_exceeded")
        assert(quotaExceeded.tone == .red)
        assert(!quotaExceeded.canToggle)

        for status in ["reauth_required", "deactivated"] {
            let presentation = accountStatusPresentation(status)
            assert(presentation.tone == .red)
            assert(!presentation.canToggle)
        }

        assert(nextRoutingPolicy(after: "normal") == "burn_first")
        assert(nextRoutingPolicy(after: "burn_first") == "preserve")
        assert(nextRoutingPolicy(after: "preserve") == "normal")

        // Reset credit gating mirrors server _NON_REDEEMABLE_STATUSES.
        assert(canRedeemResetCredit(status: "active", availableCount: 1))
        assert(canRedeemResetCredit(status: "rate_limited", availableCount: 2))
        assert(canRedeemResetCredit(status: "quota_exceeded", availableCount: 1))
        assert(!canRedeemResetCredit(status: "active", availableCount: 0))
        for status in ["paused", "reauth_required", "deactivated"] {
            assert(!canRedeemResetCredit(status: status, availableCount: 5))
        }

        assert(compactRemaining(until: now.addingTimeInterval(3 * 86_400 + 2 * 3_600), now: now) == "3d 2h")
        assert(compactRemaining(until: now.addingTimeInterval(90 * 60), now: now) == "1h 30m")
        assert(compactRemaining(until: now.addingTimeInterval(30), now: now) == "1m")
        assert(compactRemaining(until: now.addingTimeInterval(-5), now: now) == "now")

        let confirmation = resetCreditConfirmationText(
            accountName: "Work",
            availableCount: 2,
            soonestExpiresAt: now.addingTimeInterval(86_400),
            otherExpiries: [now.addingTimeInterval(2 * 86_400)],
            now: now,
            formatDate: { _ in "DATE" }
        )
        assert(confirmation.contains("Account: Work"))
        assert(confirmation.contains("Available reset credits: 2"))
        assert(confirmation.contains("Will use: credit expiring DATE (in 1d 0h)"))
        assert(confirmation.contains("Other: expires DATE (in 2d 0h)"))
        assert(confirmation.contains("cannot be undone"))
        let noExpiry = resetCreditConfirmationText(
            accountName: "A", availableCount: 1, soonestExpiresAt: nil, otherExpiries: [], now: now, formatDate: { _ in "" }
        )
        assert(noExpiry.contains("no expiry data"))

        assert(resetCreditResultText(windowsReset: 1) == "Reset 1 rate-limit window.")
        assert(resetCreditResultText(windowsReset: 2) == "Reset 2 rate-limit windows.")
        assert(resetCreditResultText(windowsReset: nil) == "Reset credit redeemed.")

        assert(accountNeedsReauthentication("reauth_required"))
        assert(accountNeedsReauthentication("deactivated"))
        assert(!accountNeedsReauthentication("active"))
        assert(!accountNeedsReauthentication("paused"))

        assert(oauthFlowOutcome("success") == .success)
        assert(oauthFlowOutcome("error") == .error)
        assert(oauthFlowOutcome("pending") == .pending)
        assert(oauthFlowOutcome("idle") == .pending)

        let envelope = Data(#"{"error":{"code":"no_available_reset_credit","message":"No available reset credit"}}"#.utf8)
        assert(dashboardErrorMessage(from: envelope) == "No available reset credit")
        assert(dashboardErrorMessage(from: Data(#"{"detail":"Not Found"}"#.utf8)) == "Not Found")
        assert(dashboardErrorMessage(from: Data(#"{"detail":[{"msg":"field required"}]}"#.utf8)) == "field required")
        assert(dashboardErrorMessage(from: Data("<html>".utf8)) == nil)

        print("StatusBarLogicTests passed")
    }

    static func aggregationAndAlertTests() {
        // The reported scenario: 0% (rate limited), 5%, 100% -> average over all three, not just 5% and 100%.
        let accounts: [(status: String, primary: Double?)] = [
            ("rate_limited", 0), ("active", 5), ("active", 100), ("reauth_required", 80), ("paused", 90),
        ]
        let counted = accounts.filter { isCountedForQuota(status: $0.status) }.map(\.primary)
        assert(counted.count == 3)
        assert(averageRemaining(counted) == 35)
        assert(isCountedForQuota(status: "quota_exceeded"))
        assert(!isCountedForQuota(status: "deactivated"))

        let segments = statusTitleSegments(primary: 35, secondary: 8, monthly: nil, activeCount: 2, totalCount: 5, attentionCount: 1)
        assert(segments.map(\.text) == ["!", "5h 35%", "W 8%", "(2/5)"])
        assert(segments[0].kind == .attention)
        assert(segments[1].kind == .quota(.amber))
        assert(segments[2].kind == .quota(.red))
        assert(segments[3].kind == .count)
        assert(!statusTitleSegments(primary: 90, secondary: nil, monthly: nil, activeCount: 1, totalCount: 1, attentionCount: 0)
            .contains { $0.kind == .attention })

        assert(quotaAlertLevel(50) == nil)
        assert(quotaAlertLevel(29) == 30)
        assert(quotaAlertLevel(9) == 10)

        var tracker = QuotaAlertTracker()
        assert(tracker.update(key: "5h", percent: 20) == nil)   // baseline is silent even below 30
        assert(tracker.update(key: "5h", percent: 15) == nil)   // same level
        assert(tracker.update(key: "5h", percent: 8) == 10)     // crossed 10
        assert(tracker.update(key: "5h", percent: 12) == nil)   // within hysteresis, stays at 10
        assert(tracker.update(key: "5h", percent: 9) == nil)    // no re-alert
        assert(tracker.update(key: "5h", percent: 40) == nil)   // recovered, re-armed
        assert(tracker.update(key: "5h", percent: 29) == 30)    // alerts again
        assert(tracker.update(key: "5h", percent: nil) == nil)  // unknown keeps state
        assert(tracker.update(key: "5h", percent: 5) == 10)
        assert(tracker.update(key: "W", percent: 50) == nil)
        assert(tracker.update(key: "W", percent: 29.5) == 30)

        let transitions = accountsNeedingNewReauthAlert(
            previous: ["a": "active", "b": "reauth_required", "c": "rate_limited"],
            current: ["a": "reauth_required", "b": "reauth_required", "c": "deactivated", "d": "reauth_required"]
        )
        assert(transitions == ["a", "c"])

        assert(statusSegmentTone(.quota(.amber), mode: .full) == .amber)
        assert(statusSegmentTone(.quota(.green), mode: .full) == .green)
        assert(statusSegmentTone(.attention, mode: .full) == .red)
        assert(statusSegmentTone(.count, mode: .full) == nil)
        assert(statusSegmentTone(.quota(.amber), mode: .warningsOnly) == nil)
        assert(statusSegmentTone(.quota(.green), mode: .warningsOnly) == nil)
        assert(statusSegmentTone(.quota(.red), mode: .warningsOnly) == .red)
        assert(statusSegmentTone(.attention, mode: .warningsOnly) == .red)
        for kind: StatusTitleSegment.Kind in [.attention, .quota(.red), .quota(.green), .count] {
            assert(statusSegmentTone(kind, mode: .off) == nil)
        }
    }

    static func displayAndPaceTests() {
        let all = StatusBarItems()
        func texts(_ items: StatusBarItems, _ style: StatusBarStyle, primary: Double? = 35, secondary: Double? = 8, monthly: Double? = nil, attention: Int = 1) -> [String] {
            statusTitleSegments(primary: primary, secondary: secondary, monthly: monthly, activeCount: 2, totalCount: 3,
                                attentionCount: attention, items: items, style: style).map(\.text)
        }
        assert(texts(all, .text) == ["!", "5h 35%", "W 8%", "(2/3)"])
        assert(texts(all, .meter) == ["!", "(2/3)"])
        assert(texts(all, .meterAndText) == ["!", "5h 35%", "W 8%", "(2/3)"])
        assert(texts(StatusBarItems(primary: true, secondary: false, accountCount: false), .text) == ["!", "5h 35%"])
        assert(texts(StatusBarItems(primary: false, secondary: false, accountCount: false), .text, attention: 0) == ["(2/3)"])
        assert(texts(StatusBarItems(primary: false, secondary: false, accountCount: false), .meter, attention: 0).isEmpty)
        assert(texts(all, .text, primary: nil, secondary: nil, monthly: 50, attention: 0) == ["M 50%", "(2/3)"])

        let now = Date(timeIntervalSince1970: 1_000_000)
        // 5h window, 1h elapsed (20%), 10% used -> 10% in reserve, lasts until reset.
        let reserve = quotaPace(remainingPercent: 90, resetAt: now.addingTimeInterval(4 * 3_600), windowMinutes: 300, now: now)!
        assert(abs(reserve.expectedRemainingPercent - 80) < 0.001)
        assert(reserve.paceLabel == "10% in reserve")
        assert(reserve.runsOutIn == nil && reserve.runwayLabel == "Lasts until reset")
        // 1h elapsed, 50% used -> runs out in 1h, 30% over pace.
        let fast = quotaPace(remainingPercent: 50, resetAt: now.addingTimeInterval(4 * 3_600), windowMinutes: 300, now: now)!
        assert(fast.paceLabel == "30% over pace")
        assert(fast.runwayLabel == "Runs out in 1h 0m" && fast.isAtRisk)
        let even = quotaPace(remainingPercent: 79, resetAt: now.addingTimeInterval(4 * 3_600), windowMinutes: 300, now: now)!
        assert(even.paceLabel == "On pace")
        let empty = quotaPace(remainingPercent: 0, resetAt: now.addingTimeInterval(3_600), windowMinutes: 300, now: now)!
        assert(empty.exhausted && empty.paceLabel == "Exhausted" && empty.runwayLabel == "Empty until reset")
        let unused = quotaPace(remainingPercent: 100, resetAt: now.addingTimeInterval(3_600), windowMinutes: 300, now: now)!
        assert(unused.runsOutIn == nil && unused.paceLabel == "80% in reserve")
        assert(quotaPace(remainingPercent: 99, resetAt: now.addingTimeInterval(299 * 60), windowMinutes: 300, now: now) == nil)
        assert(quotaPace(remainingPercent: 50, resetAt: nil, windowMinutes: 300, now: now) == nil)
        assert(quotaPace(remainingPercent: 50, resetAt: now.addingTimeInterval(-5), windowMinutes: 300, now: now) == nil)

        assert(relativeUpdatedLabel(now.addingTimeInterval(-20), now: now) == "Updated just now")
        assert(relativeUpdatedLabel(now.addingTimeInterval(-300), now: now) == "Updated 5m ago")
        assert(relativeUpdatedLabel(now.addingTimeInterval(-7_200), now: now) == "Updated 2h 0m ago")
        assert(relativeUpdatedLabel(nil, now: now) == nil)

        assert(resetCreditSummaryText(count: 1, expiresAt: now.addingTimeInterval(28 * 86_400 + 2 * 3_600), now: now)
            == "1 reset · 28d 2h")
        assert(resetCreditSummaryText(count: 3, expiresAt: nil, now: now) == "3 resets")
        assert(resetCreditSummaryText(count: 0, expiresAt: nil, now: now) == nil)

        assert(formatCompactCount(5_900_000_000) == "5.9B")
        assert(formatCompactCount(85_000_000) == "85M")
        assert(formatCompactCount(123_456) == "123K")
        assert(formatCompactCount(1_000) == "1K")
        assert(formatCompactCount(999) == "999")
        assert(formatUSD(51.56) == "$51.56")
        assert(formatUSD(5_251.23) == "$5,251.23")
        assert(formatUSD(12_345) == "$12.3K")
    }

    static func versionTests() {
        assert(isNewerVersion("v0.3.1", than: "0.3.0"))
        assert(isNewerVersion("0.10.0", than: "0.9.9"))
        assert(!isNewerVersion("0.3.0", than: "0.3.0"))
        assert(!isNewerVersion("v0.2.9", than: "0.3.0"))
        assert(isNewerVersion("1.24.0", than: "1.24.0-beta.3"))
        assert(isNewerVersion("1.24.0-beta.10", than: "1.24.0-beta.9"))
        assert(!isNewerVersion("1.24.0-beta.3", than: "1.24.0"))
        assert(compareVersions("1.2", "1.2.0") == .orderedSame)
        assert(compareVersions("1.2.0+build5", "1.2.0") == .orderedSame)

        assert(isAppUpdateAsset("CodexLBStatusBar-0.3.1.dmg"))
        assert(!isAppUpdateAsset("CodexLBStatusBar-0.3.1.zip"))
        assert(!isAppUpdateAsset("Other-0.3.1.dmg"))

        let hex = String(repeating: "ab", count: 32)
        assert(sha256FromDigest("sha256:" + hex) == hex)
        assert(sha256FromDigest("SHA256:" + hex.uppercased()) == hex)
        assert(sha256FromDigest("sha512:" + hex) == nil)
        assert(sha256FromDigest("sha256:xyz") == nil)
        assert(sha256FromDigest(nil) == nil)

        assert(canSelfUpdate(bundlePath: "/Applications/CodexLBStatusBar.app"))
        assert(!canSelfUpdate(bundlePath: "/Volumes/Codex LB Status v0.3.0/CodexLBStatusBar.app"))
        assert(!canSelfUpdate(bundlePath: "/private/var/folders/x/AppTranslocation/ABC/d/CodexLBStatusBar.app"))
        assert(!canSelfUpdate(bundlePath: "/usr/local/bin/CodexLBStatusBar"))
    }

    static func accountListTests() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        func key(_ id: String, _ status: String, _ p: Double?, _ s: Double?, pr: Double? = nil, sr: Double? = nil) -> AccountSortKey {
            AccountSortKey(id: id, name: id, status: status, primaryRemaining: p, secondaryRemaining: s,
                           primaryResetAt: pr.map { now.addingTimeInterval($0) }, secondaryResetAt: sr.map { now.addingTimeInterval($0) })
        }
        let keys = [
            key("b", "active", 80, 20, pr: 3_600, sr: 86_400),   // bottleneck weekly 20, resets in 1d
            key("a", "active", 90, 95, pr: 7_200, sr: 5 * 86_400),
            key("c", "rate_limited", 0, 50, pr: 600, sr: 86_400), // bottleneck 5h 0, resets in 10m
            key("d", "paused", nil, nil),
        ]
        assert(orderedAccountIDs(keys, sort: .status, filter: .all) == ["a", "b", "c", "d"])
        assert(orderedAccountIDs(keys, sort: .remaining, filter: .all) == ["a", "b", "c", "d"])
        assert(orderedAccountIDs(keys, sort: .resetSoonest, filter: .all) == ["c", "a", "b", "d"])
        assert(orderedAccountIDs(keys, sort: .name, filter: .all) == ["a", "b", "c", "d"])
        assert(orderedAccountIDs(keys, sort: .status, filter: .attention) == ["b", "c", "d"])
        assert(keys[0].bottleneckRemaining == 20)
        assert(AccountSortOrder.name.next == .status)

        assert(resetCreditExpiresSoon(count: 2, expiresAt: now.addingTimeInterval(3_600), now: now))
        assert(!resetCreditExpiresSoon(count: 2, expiresAt: now.addingTimeInterval(2 * 86_400), now: now))
        assert(!resetCreditExpiresSoon(count: 0, expiresAt: now.addingTimeInterval(3_600), now: now))
        assert(!resetCreditExpiresSoon(count: 1, expiresAt: now.addingTimeInterval(-1), now: now))
        assert(resetCreditExpiryAlertKey(accountId: "x", expiresAt: now) == "x|2000000")

        assert(staleDataLabel(lastSuccess: nil, now: now) == "Offline")
        assert(staleDataLabel(lastSuccess: now.addingTimeInterval(-10), now: now) == "Offline · data from just now")
        assert(staleDataLabel(lastSuccess: now.addingTimeInterval(-300), now: now) == "Offline · data from 5m ago")
    }
}
