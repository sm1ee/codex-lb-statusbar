import Foundation

enum QuotaTone {
    case green
    case amber
    case red
}

enum RoutingBadgeTone {
    case neutral
    case burnFirst
    case preserve
}

enum AccountStatusTone {
    case green
    case amber
    case red
}

struct AccountStatusPresentation {
    let label: String
    let tone: AccountStatusTone
    let canToggle: Bool
}

func accountStatusPresentation(_ value: String) -> AccountStatusPresentation {
    switch value {
    case "active":
        return AccountStatusPresentation(label: "Active", tone: .green, canToggle: true)
    case "paused":
        return AccountStatusPresentation(label: "Paused", tone: .amber, canToggle: true)
    case "rate_limited":
        return AccountStatusPresentation(label: "Rate limited", tone: .amber, canToggle: false)
    case "quota_exceeded":
        return AccountStatusPresentation(label: "Quota exceeded", tone: .red, canToggle: false)
    case "reauth_required":
        return AccountStatusPresentation(label: "Re-auth required", tone: .red, canToggle: false)
    case "deactivated":
        return AccountStatusPresentation(label: "Deactivated", tone: .red, canToggle: false)
    default:
        return AccountStatusPresentation(label: value, tone: .red, canToggle: false)
    }
}

func nextRoutingPolicy(after value: String) -> String {
    switch value {
    case "normal":
        return "burn_first"
    case "burn_first":
        return "preserve"
    default:
        return "normal"
    }
}

struct RoutingBadgePresentation {
    let label: String
    let tone: RoutingBadgeTone
    let symbolName: String?
}

func routingBadgePresentation(_ value: String) -> RoutingBadgePresentation {
    switch value {
    case "burn_first":
        return RoutingBadgePresentation(label: "Burn first", tone: .burnFirst, symbolName: "flame.fill")
    case "preserve":
        return RoutingBadgePresentation(label: "Preserve", tone: .preserve, symbolName: "shield")
    case "normal":
        return RoutingBadgePresentation(label: "Normal", tone: .neutral, symbolName: nil)
    default:
        return RoutingBadgePresentation(label: value, tone: .neutral, symbolName: nil)
    }
}

func quotaTone(for percent: Double) -> QuotaTone {
    if percent >= 70 {
        return .green
    }
    if percent >= 30 {
        return .amber
    }
    return .red
}

func compactResetCreditLabel(count: Int, expiresAt: Date?, now: Date = Date()) -> String? {
    guard count > 0 else {
        return nil
    }
    guard let expiresAt else {
        return "Reset \(count)"
    }

    let seconds = max(0, Int(expiresAt.timeIntervalSince(now)))
    let value: String
    if seconds >= 86_400 {
        value = "\(seconds / 86_400)d"
    } else if seconds >= 3_600 {
        value = "\(seconds / 3_600)h"
    } else if seconds > 0 {
        value = "\(max(1, seconds / 60))m"
    } else {
        value = "now"
    }
    return "Reset \(count) / \(value)"
}

func elapsedTime(since date: Date, now: Date = Date()) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    let days = seconds / 86_400
    let hours = (seconds % 86_400) / 3_600
    let minutes = (seconds % 3_600) / 60
    if days > 0 {
        return "\(days)d \(hours)h"
    }
    if hours > 0 {
        return "\(hours)h \(minutes)m"
    }
    return "\(max(1, minutes))m"
}

func refreshStatusLabel(isRefreshing: Bool, lastRefreshedAt: Date?) -> String? {
    if isRefreshing {
        return "Refreshing..."
    }
    guard let lastRefreshedAt else {
        return nil
    }
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .medium
    return "Updated \(formatter.string(from: lastRefreshedAt))"
}

func codexLBVersionLabel(_ version: String?) -> String {
    guard let version = version?.trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty else {
        return "Codex LB version unavailable"
    }
    return "Codex LB \(version)"
}

func averageRemaining(_ values: [Double?]) -> Double? {
    let available = values.compactMap { $0 }
    guard !available.isEmpty else {
        return nil
    }
    return available.reduce(0, +) / Double(available.count)
}

func quotaSummaryTitle(
    primary: Double?,
    secondary: Double?,
    monthly: Double?,
    activeCount: Int,
    totalCount: Int
) -> String {
    statusTitleSegments(
        primary: primary,
        secondary: secondary,
        monthly: monthly,
        activeCount: activeCount,
        totalCount: totalCount,
        attentionCount: 0
    ).map(\.text).joined(separator: " ")
}

// MARK: - Aggregation

/// Accounts excluded from the quota average: they cannot serve traffic until an operator acts.
/// Rate-limited / quota-exceeded accounts stay in (usually at 0%) so the average doesn't jump
/// when one of them drops out or comes back.
private let quotaExcludedStatuses: Set<String> = ["paused", "reauth_required", "deactivated"]

func isCountedForQuota(status: String) -> Bool {
    !quotaExcludedStatuses.contains(status)
}

// MARK: - Status bar title

struct StatusTitleSegment: Equatable {
    enum Kind: Equatable {
        case attention
        case quota(QuotaTone)
        case count
    }

    let text: String
    let kind: Kind
}

func statusTitleSegments(
    primary: Double?,
    secondary: Double?,
    monthly: Double?,
    activeCount: Int,
    totalCount: Int,
    attentionCount: Int
) -> [StatusTitleSegment] {
    var segments: [StatusTitleSegment] = []
    if attentionCount > 0 {
        segments.append(StatusTitleSegment(text: "!", kind: .attention))
    }
    func quota(_ label: String, _ value: Double) {
        segments.append(StatusTitleSegment(text: "\(label) \(Int(round(value)))%", kind: .quota(quotaTone(for: value))))
    }
    if let primary {
        quota("5h", primary)
    }
    if let secondary {
        quota("W", secondary)
    }
    if primary == nil, secondary == nil, let monthly {
        quota("M", monthly)
    }
    segments.append(StatusTitleSegment(text: "(\(activeCount)/\(totalCount))", kind: .count))
    return segments
}

// MARK: - Notifications

let quotaAlertThresholds: [Double] = [30, 10]
private let quotaAlertHysteresis: Double = 5

/// Lowest threshold the value is below (e.g. 25% -> 30, 4% -> 10), or nil when above all thresholds.
func quotaAlertLevel(_ percent: Double) -> Double? {
    quotaAlertThresholds.filter { percent < $0 }.min()
}

/// Tracks aggregate quota per window and reports when a lower alert threshold is crossed.
/// The first observation per key is a silent baseline, and a level only re-arms after the value
/// rises `quotaAlertHysteresis` points above it, so hovering around a threshold doesn't spam.
struct QuotaAlertTracker {
    private var levels: [String: Double] = [:]  // .infinity == no alert level

    mutating func reset() {
        levels.removeAll()
    }

    /// Returns the newly crossed threshold, if a notification should be sent.
    mutating func update(key: String, percent: Double?) -> Double? {
        guard let percent else {
            return nil
        }
        let raw = quotaAlertLevel(percent) ?? .infinity
        guard let previous = levels[key] else {
            levels[key] = raw
            return nil
        }
        var next = raw
        if raw > previous, previous.isFinite, percent < previous + quotaAlertHysteresis {
            next = previous
        }
        levels[key] = next
        return next < previous ? next : nil
    }
}

/// Account ids that moved into a re-auth/deactivated state since the previous refresh.
/// Accounts not seen before are ignored (no alert on first load or right after an import).
func accountsNeedingNewReauthAlert(previous: [String: String], current: [String: String]) -> [String] {
    current.compactMap { accountId, status in
        guard accountNeedsReauthentication(status),
              let previousStatus = previous[accountId],
              !accountNeedsReauthentication(previousStatus) else {
            return nil
        }
        return accountId
    }.sorted()
}

// MARK: - Reset credits

private let nonRedeemableStatuses: Set<String> = ["paused", "reauth_required", "deactivated"]

/// Mirrors the server's `_NON_REDEEMABLE_STATUSES` gate so the button is only offered when consume can succeed.
func canRedeemResetCredit(status: String, availableCount: Int) -> Bool {
    availableCount > 0 && !nonRedeemableStatuses.contains(status)
}

func compactRemaining(until date: Date, now: Date = Date()) -> String {
    let seconds = Int(date.timeIntervalSince(now))
    if seconds <= 0 {
        return "now"
    }
    if seconds >= 86_400 {
        return "\(seconds / 86_400)d \((seconds % 86_400) / 3_600)h"
    }
    if seconds >= 3_600 {
        return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m"
    }
    return "\(max(1, seconds / 60))m"
}

func resetCreditConfirmationText(
    accountName: String,
    availableCount: Int,
    soonestExpiresAt: Date?,
    otherExpiries: [Date],
    now: Date = Date(),
    formatDate: (Date) -> String
) -> String {
    var lines = [
        "Account: \(accountName)",
        "Available reset credits: \(availableCount)",
    ]
    if let soonestExpiresAt {
        lines.append("Will use: credit expiring \(formatDate(soonestExpiresAt)) (in \(compactRemaining(until: soonestExpiresAt, now: now)))")
    } else {
        lines.append("Will use: the soonest-expiring credit (no expiry data)")
    }
    for expiry in otherExpiries.prefix(3) {
        lines.append("Other: expires \(formatDate(expiry)) (in \(compactRemaining(until: expiry, now: now)))")
    }
    if otherExpiries.count > 3 {
        lines.append("... and \(otherExpiries.count - 3) more")
    }
    lines.append("")
    lines.append("This resets the account's rate-limit windows immediately and cannot be undone.")
    return lines.joined(separator: "\n")
}

func resetCreditResultText(windowsReset: Int?) -> String {
    guard let windowsReset else {
        return "Reset credit redeemed."
    }
    return windowsReset == 1 ? "Reset 1 rate-limit window." : "Reset \(windowsReset) rate-limit windows."
}

// MARK: - Re-authentication

func accountNeedsReauthentication(_ status: String) -> Bool {
    status == "reauth_required" || status == "deactivated"
}

enum OAuthFlowOutcome {
    case pending
    case success
    case error
}

func oauthFlowOutcome(_ status: String) -> OAuthFlowOutcome {
    switch status {
    case "success":
        return .success
    case "error":
        return .error
    default:
        return .pending
    }
}

// MARK: - Errors

/// Extracts a human-readable message from codex-lb error envelopes:
/// `{"error": {"code", "message"}}` (dashboard) or `{"detail": "..." | [{"msg": ...}]}` (FastAPI validation).
func dashboardErrorMessage(from body: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
        return nil
    }
    if let error = object["error"] as? [String: Any],
       let message = error["message"] as? String,
       !message.isEmpty {
        return message
    }
    if let detail = object["detail"] as? String, !detail.isEmpty {
        return detail
    }
    if let details = object["detail"] as? [[String: Any]] {
        let messages = details.compactMap { $0["msg"] as? String }
        if !messages.isEmpty {
            return messages.joined(separator: "; ")
        }
    }
    return nil
}
