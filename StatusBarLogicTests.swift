import Foundation

@main
private enum StatusBarLogicTests {
    static func main() {
        aggregationAndAlertTests()
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
    }
}
