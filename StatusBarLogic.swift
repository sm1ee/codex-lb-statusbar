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
    var parts: [String] = []
    if let primary {
        parts.append("5h \(Int(round(primary)))%")
    }
    if let secondary {
        parts.append("W \(Int(round(secondary)))%")
    }
    if primary == nil, secondary == nil, let monthly {
        parts.append("M \(Int(round(monthly)))%")
    }
    parts.append("(\(activeCount)/\(totalCount))")
    return parts.joined(separator: " ")
}
