import Foundation

@main
private enum StatusBarLogicTests {
    static func main() {
        aggregationAndAlertTests()
        displayAndPaceTests()
        versionTests()
        accountListTests()
        numericSafetyTests()
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
        // Usage Only: text (including the !) stays plain, the usage bar keeps every tone.
        for kind: StatusTitleSegment.Kind in [.attention, .quota(.red), .quota(.green), .count] {
            assert(statusSegmentTone(kind, mode: .meterOnly) == nil)
        }
        assert(statusMeterTone(.amber, mode: .full) == .amber)
        assert(statusMeterTone(.amber, mode: .meterOnly) == .amber)
        assert(statusMeterTone(.red, mode: .meterOnly) == .red)
        assert(statusMeterTone(.amber, mode: .warningsOnly) == nil)
        assert(statusMeterTone(.red, mode: .warningsOnly) == .red)
        assert(statusMeterTone(.green, mode: .off) == nil)
    }

    static func displayAndPaceTests() {
        let all = StatusBarItems()
        func texts(_ items: StatusBarItems, _ components: StatusBarComponents, primary: Double? = 35, secondary: Double? = 8, monthly: Double? = nil, attention: Int = 1) -> [String] {
            statusTitleSegments(primary: primary, secondary: secondary, monthly: monthly, activeCount: 2, totalCount: 3,
                                attentionCount: attention, items: items, components: components).map(\.text)
        }
        // Quota text and the count are no longer components: only the `!` renders as text.
        assert(texts(all, StatusBarComponents()) == ["!"])
        assert(texts(all, StatusBarComponents(), attention: 0).isEmpty)
        assert(texts(all, StatusBarComponents(), primary: nil, secondary: nil, monthly: 50, attention: 0).isEmpty)
        assert(StatusBarComponents(rawValue: "usage,chart") == StatusBarComponents(usage: true, chart: true))
        assert(StatusBarComponents(rawValue: "meter,graph") == StatusBarComponents(usage: true, chart: true))  // pre-rename flags
        assert(StatusBarComponents(rawValue: "text,meter,count,logo") == StatusBarComponents(usage: true))  // legacy flags ignored
        assert(StatusBarComponents(rawValue: "") == StatusBarComponents(usage: false, chart: false))

        // Accounts meter: counted accounts only, kept in server order, capped with overflow.
        let accountKeys = [
            AccountQuotaKey(status: "active", remaining: 88, label: "alice", accountId: "acc-1"),
            AccountQuotaKey(status: "active", remaining: 36, label: "bob", accountId: "acc-2"),
            AccountQuotaKey(status: "rate_limited", remaining: 0, label: "carol", accountId: "acc-3"),
            AccountQuotaKey(status: "paused", remaining: 90, label: "frank", accountId: "acc-4"),
            AccountQuotaKey(status: "reauth_required", remaining: 80, label: "grace", accountId: "acc-5"),
            AccountQuotaKey(status: "deactivated", remaining: 70, label: "heidi", accountId: "acc-6"),
            AccountQuotaKey(status: "active", remaining: nil, label: "ivan", accountId: "acc-7"),
        ]
        let meter = statusBarAccountMeter(accountKeys)  // default: usage, worst first
        assert(meter.entries.map(\.value) == [0, 36, 88].map { $0 as Double? })
        assert(meter.entries.map(\.label) == ["carol", "bob", "alice"])
        assert(meter.entries.map(\.accountId) == ["acc-3", "acc-2", "acc-1"])
        assert(meter.overflow == 0)
        let server = statusBarAccountMeter(accountKeys, sort: .server)
        assert(server.entries.map(\.value) == [88, 36, 0].map { $0 as Double? })
        let best = statusBarAccountMeter(accountKeys, sort: .usageBest)
        assert(best.entries.map(\.value) == [88, 36, 0].map { $0 as Double? })
        let byName = statusBarAccountMeter(accountKeys, sort: .name)
        assert(byName.entries.map(\.label) == ["alice", "bob", "carol"])
        let many = statusBarAccountMeter((0..<10).map { AccountQuotaKey(status: "active", remaining: Double($0)) })
        assert(many.entries.map(\.value) == [0, 1, 2, 3, 4, 5, 6, 7, 8, 9].map { $0 as Double? })
        assert(many.overflow == 0)
        let capped = statusBarAccountMeter((0..<20).map { AccountQuotaKey(status: "active", remaining: Double($0)) })
        assert(capped.entries.map(\.value) == [0, 1, 2, 3, 4, 5, 6, 7, 8, 9].map { $0 as Double? })
        assert(capped.overflow == 10)
        assert(statusBarAccountMeter([]).entries.isEmpty)
        assert(statusBarAccountMeter([AccountQuotaKey(status: "paused", remaining: 50)]).entries.isEmpty)
        // Labels keep as much of the name as fits the bar width, marker included (6pt per character
        // here, 42pt bars).
        let measure: (String) -> CGFloat = { CGFloat($0.count) * 6 }
        assert(accountMeterLabel(email: "alice@example.com", maxWidth: 42, width: measure) == "alice")
        assert(accountMeterLabel(email: "john.doe@example.com", maxWidth: 42, width: measure) == "john..")
        assert(accountMeterLabel(email: "abcdefgh@example.com", maxWidth: 42, width: measure) == "abcde..")
        assert(accountMeterLabel(email: "a@example.com", maxWidth: 42, width: measure) == "a")
        assert(accountMeterLabel("smlee@example.com", maxWidth: 42, width: measure) == "smlee..")
        assert(accountMeterLabel("smlee", maxWidth: 42, width: measure) == "smlee")
        assert(accountMeterLabel("", maxWidth: 42, width: measure) == nil)
        // No room for the marker either: it stands alone rather than dropping the ellipsis.
        assert(accountMeterLabel("abcdef", maxWidth: 10, width: measure) == "..")
        assert(accountMeterLabel(email: "@example.com", maxWidth: 42, width: measure) == nil)
        assert(accountMeterLabel(email: "no-at-sign", maxWidth: 42, width: measure) == nil)
        assert(accountMeterLabel(email: nil, maxWidth: 42, width: measure) == nil)
        assert(accountEmailPrefix("john.doe@example.com") == "john.doe")
        assert(accountEmailPrefix("@example.com") == "")

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
        // Server update checks scan the release list instead of trusting GitHub's ordering.
        assert(newestVersionTag(["v1.24.0", "v1.25.0-beta.9", "v1.23.0"]) == "v1.25.0-beta.9")
        assert(newestVersionTag(["v1.23.0", "v1.24.0"]) == "v1.24.0")
        assert(newestVersionTag(["v1.25.0-beta.9", "v1.24.0"]) == "v1.25.0-beta.9")
        assert(newestVersionTag([]) == nil)

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

    /// Server numbers are untrusted: display conversions clamp instead of trapping, and the rounded
    /// percent drives both the label and the tone so "70%" is never drawn as amber.
    static func numericSafetyTests() {
        assert(percentInt(69.6) == 70)
        assert(percentInt(0) == 0)
        assert(percentInt(100.4) == 100)
        assert(percentInt(-7) == 0)
        assert(percentInt(1e20) == 100)
        assert(percentInt(.nan) == 0)
        assert(percentInt(.infinity) == 0)

        assert(formatCompactCount(999) == "999")
        assert(formatCompactCount(1_260_000) == "1.3M")
        assert(formatCompactCount(5_900_000_000) == "5.9B")
        assert(formatCompactCount(999_950) == "1M")             // used to read "1000K"
        assert(formatCompactCount(999_999_999_999) == "1T")
        assert(formatCompactCount(.infinity) == "--")

        let segments = statusTitleSegments(primary: 69.6, secondary: 29.6, monthly: nil, activeCount: 1, totalCount: 2, attentionCount: 0)
        assert(segments.map(\.text) == ["5h 70%", "W 30%", "(1/2)"])
        assert(segments[0].kind == .quota(.green))
        assert(segments[1].kind == .quota(.amber))
    }
}
