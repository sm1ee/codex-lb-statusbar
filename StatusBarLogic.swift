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

// MARK: - Status bar color mode

enum StatusBarColorMode: String, CaseIterable {
    /// Every quota segment is green/amber/red, plus a red `!`.
    case full
    /// Only the usage bar is colored; all text (including the `!`) keeps the default menu-bar color.
    case meterOnly
    /// Plain text; only the `!` and quota below 30% are red.
    case warningsOnly
    /// Plain text everywhere, including the `!`.
    case off

    var menuTitle: String {
        switch self {
        case .full:
            return "Full Color"
        case .meterOnly:
            return "Usage Only"
        case .warningsOnly:
            return "Warnings Only"
        case .off:
            return "Monochrome"
        }
    }
}

/// Color to apply to a status-bar text segment, or nil for the default menu-bar text color.
func statusSegmentTone(_ kind: StatusTitleSegment.Kind, mode: StatusBarColorMode) -> QuotaTone? {
    switch (mode, kind) {
    case (.off, _), (.meterOnly, _), (_, .count):
        return nil
    case (_, .attention):
        return .red
    case (.full, .quota(let tone)):
        return tone
    case (.warningsOnly, .quota(let tone)):
        return tone == .red ? .red : nil
    }
}

/// Color to apply to the meter image, or nil for the default menu-bar color.
func statusMeterTone(_ tone: QuotaTone, mode: StatusBarColorMode) -> QuotaTone? {
    switch mode {
    case .off:
        return nil
    case .full, .meterOnly:
        return tone
    case .warningsOnly:
        return tone == .red ? .red : nil
    }
}

// MARK: - Status bar display options

/// Independent status-bar components, OR-combined: each toggle adds its own element
/// (Usage -> quota bar, Chart -> usage sparkline). Quota text and the account count were removed
/// as components: the bars show percents, and the app logo appears only when every component
/// is off, keeping the item visible and clickable.
struct StatusBarComponents: Equatable {
    var usage = true
    var chart = false

    /// Comma-joined flag list; an empty string means every component is off.
    var rawValue: String {
        var parts: [String] = []
        if usage { parts.append("usage") }
        if chart { parts.append("chart") }
        return parts.joined(separator: ",")
    }

    init(usage: Bool = true, chart: Bool = false) {
        self.usage = usage
        self.chart = chart
    }

    init(rawValue: String) {
        let parts = Set(rawValue.split(separator: ",").map(String.init))
        // "meter" was the pre-rename flag name.
        usage = parts.contains("usage") || parts.contains("meter")
        // "graph" was the pre-rename flag name.
        chart = parts.contains("chart") || parts.contains("graph")
    }
}

struct StatusBarItems: Equatable {
    var primary = true
    var secondary = true
}

/// Usage bar shapes. `.combined*` stack one rounded bar per shown window (5h, Weekly), with
/// `.combinedPercent` adding the first window's percent beside them. `.accounts*` draw one bar per
/// counted account with the percent beside it, optionally with the email prefix above each bar
/// (the same name + percent + bar layout as the account cards).
enum MeterStyle: String, CaseIterable {
    /// Raw values are persisted in the preferences; they stay put across renames.
    case combined = "pill"
    case combinedPercent = "pillPercent"
    case accounts
    case accountsLabeled

    var title: String {
        switch self {
        case .combined:
            return "Combined"
        case .combinedPercent:
            return "Combined + Percent"
        case .accounts:
            return "Accounts"
        case .accountsLabeled:
            return "Accounts + Name"
        }
    }
}

/// Minimal account facts for the status-bar accounts meter, decoupled from the Decodable model.
struct AccountQuotaKey {
    let status: String
    let remaining: Double?
    let label: String?
    let accountId: String?

    init(status: String, remaining: Double?, label: String? = nil, accountId: String? = nil) {
        self.status = status
        self.remaining = remaining
        self.label = label
        self.accountId = accountId
    }
}

/// One bar's value and optional label for the accounts meter.
struct AccountMeterEntry: Equatable {
    let value: Double?
    let label: String?
    let accountId: String?
}

/// Accounts meter label: as much of the display string as fits `maxWidth`, measured by `width`,
/// with a `..` marker taking the last of that budget. Short values come back untouched.
func accountMeterLabel(_ value: String?, maxWidth: CGFloat, width: (String) -> CGFloat) -> String? {
    guard let value, !value.isEmpty else {
        return nil
    }
    guard width(value) > maxWidth else {
        return value
    }
    let marker = ".."
    var kept = ""
    for character in value {
        let candidate = kept + String(character)
        guard width(candidate + marker) <= maxWidth else {
            break
        }
        kept = candidate
    }
    // "john.doe" keeps "john", not "john.", so the marker doesn't trail a dot of its own.
    while kept.hasSuffix(".") {
        kept.removeLast()
    }
    return kept + marker
}

/// Email local part (before the `@`), or nil when there is no address to shorten.
func accountEmailPrefix(_ email: String?) -> String? {
    guard let email, let at = email.firstIndex(of: "@") else {
        return nil
    }
    return String(email[..<at])
}

/// Accounts meter label from an email: the local part (before `@`), truncated like any label.
func accountMeterLabel(email: String?, maxWidth: CGFloat, width: (String) -> CGFloat) -> String? {
    accountEmailPrefix(email).flatMap { accountMeterLabel($0, maxWidth: maxWidth, width: width) }
}

/// Ordering for the accounts meter.
enum AccountMeterSort: String, CaseIterable {
    case usage      // worst first
    case usageBest  // best first
    case name       // alphabetical by label
    case server     // server order

    var title: String {
        switch self {
        case .usage:
            return "Usage (worst first)"
        case .usageBest:
            return "Usage (best first)"
        case .name:
            return "Name"
        case .server:
            return "Server order"
        }
    }
}

/// Per-account remaining percents for the accounts meter: counted accounts only (same rule as the
/// quota average), capped at `maxBars` with the hidden count returned as `overflow`, ordered by
/// `sort`.
func statusBarAccountMeter(_ accounts: [AccountQuotaKey], maxBars: Int = 10, sort: AccountMeterSort = .usage) -> (entries: [AccountMeterEntry], overflow: Int) {
    var counted = accounts
        .filter { isCountedForQuota(status: $0.status) }
        .compactMap { key in key.remaining.map { AccountMeterEntry(value: $0, label: key.label, accountId: key.accountId) } }
    switch sort {
    case .usage:
        counted.sort { ($0.value ?? 0) < ($1.value ?? 0) }
    case .usageBest:
        counted.sort { ($0.value ?? 0) > ($1.value ?? 0) }
    case .name:
        counted.sort { ($0.label ?? "").localizedCaseInsensitiveCompare($1.label ?? "") == .orderedAscending }
    case .server:
        break
    }
    guard counted.count > maxBars else {
        return (counted, 0)
    }
    return (Array(counted.prefix(maxBars)), counted.count - maxBars)
}

/// Segments to render as text for the chosen components. Quota text and the account count are no
/// longer components (the meters show percents, the logo marks the item), so only the `!` attention
/// marker can render as text.
func statusTitleSegments(
    primary: Double?,
    secondary: Double?,
    monthly: Double?,
    activeCount: Int,
    totalCount: Int,
    attentionCount: Int,
    items: StatusBarItems,
    components: StatusBarComponents
) -> [StatusTitleSegment] {
    let shownPrimary = items.primary ? primary : nil
    let shownSecondary = items.secondary ? secondary : nil
    // Monthly-only plans: fall back to the monthly window when the 5h/weekly windows don't exist.
    let fallbackMonthly = primary == nil && secondary == nil && (items.primary || items.secondary) ? monthly : nil
    var segments = statusTitleSegments(
        primary: shownPrimary,
        secondary: shownSecondary,
        monthly: fallbackMonthly,
        activeCount: activeCount,
        totalCount: totalCount,
        attentionCount: attentionCount
    )
    segments.removeAll { if case .quota = $0.kind { return true } else { return false } }
    segments.removeAll { $0.kind == .count }
    return segments
}

enum UsagePeriod: String, CaseIterable {
    case day = "1d"
    case week = "7d"
    case month = "30d"

    var title: String {
        switch self {
        case .day:
            return "Last 24 hours"
        case .week:
            return "Last 7 days"
        case .month:
            return "Last 30 days"
        }
    }
}

// MARK: - Pace

struct QuotaPace: Equatable {
    /// Remaining percent expected at this point if usage were spread evenly across the window.
    let expectedRemainingPercent: Double
    /// Positive: used less than the even pace (reserve). Negative: ahead of pace.
    let deltaPercent: Double
    /// Seconds until the quota runs out at the average rate so far; nil when it lasts until reset.
    let runsOutIn: TimeInterval?
    let exhausted: Bool

    var paceLabel: String {
        if exhausted {
            return "Exhausted"
        }
        if abs(deltaPercent) < 3 {
            return "On pace"
        }
        let value = Int(round(abs(deltaPercent)))
        return deltaPercent > 0 ? "\(value)% in reserve" : "\(value)% over pace"
    }

    var runwayLabel: String {
        if exhausted {
            return "Empty until reset"
        }
        guard let runsOutIn else {
            return "Lasts until reset"
        }
        return "Runs out in \(compactRemaining(until: Date(timeIntervalSinceReferenceDate: runsOutIn), now: Date(timeIntervalSinceReferenceDate: 0)))"
    }

    var isAtRisk: Bool {
        exhausted || runsOutIn != nil
    }
}

/// Same model as the server's depletion math (`safe_usage_percent` = elapsed share of the window),
/// using the average burn rate since the window started.
func quotaPace(remainingPercent: Double, resetAt: Date?, windowMinutes: Int?, now: Date = Date()) -> QuotaPace? {
    guard let resetAt, let windowMinutes, windowMinutes > 0 else {
        return nil
    }
    let window = TimeInterval(windowMinutes) * 60
    let untilReset = resetAt.timeIntervalSince(now)
    let elapsed = window - untilReset
    // Too early (or clock skew): a few minutes of data make wild projections.
    guard untilReset > 0, elapsed >= min(600, window * 0.05) else {
        return nil
    }
    let remaining = min(max(remainingPercent, 0), 100)
    let used = 100 - remaining
    let expectedUsed = min(elapsed / window, 1) * 100
    if remaining <= 0 {
        return QuotaPace(expectedRemainingPercent: 100 - expectedUsed, deltaPercent: expectedUsed - used, runsOutIn: 0, exhausted: true)
    }
    let ratePerSecond = used / elapsed
    var runsOutIn: TimeInterval?
    if ratePerSecond > 0 {
        let timeToEmpty = remaining / ratePerSecond
        runsOutIn = timeToEmpty < untilReset ? timeToEmpty : nil
    }
    return QuotaPace(
        expectedRemainingPercent: 100 - expectedUsed,
        deltaPercent: expectedUsed - used,
        runsOutIn: runsOutIn,
        exhausted: false
    )
}

// MARK: - Card and usage formatting

func relativeUpdatedLabel(_ date: Date?, now: Date = Date()) -> String? {
    guard let date else {
        return nil
    }
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    if seconds < 60 {
        return "Updated just now"
    }
    if seconds < 3_600 {
        return "Updated \(seconds / 60)m ago"
    }
    return "Updated \(elapsedTime(since: date, now: now)) ago"
}

/// Compact card label, e.g. "3 resets · 4d 17h" (time until the soonest credit expires).
func resetCreditSummaryText(count: Int, expiresAt: Date?, now: Date = Date()) -> String? {
    guard count > 0 else {
        return nil
    }
    let available = count == 1 ? "1 reset" : "\(count) resets"
    guard let expiresAt else {
        return available
    }
    return "\(available) · \(compactRemaining(until: expiresAt, now: now))"
}

func formatCompactCount(_ value: Double) -> String {
    let magnitude = abs(value)
    let units: [(Double, String)] = [(1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "K")]
    for (threshold, suffix) in units where magnitude >= threshold {
        let scaled = value / threshold
        let text = scaled >= 100 ? String(format: "%.0f", scaled) : String(format: "%.1f", scaled)
        return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + suffix
    }
    return String(Int(round(value)))
}

func formatUSD(_ value: Double) -> String {
    if value >= 10_000 {
        return "$" + formatCompactCount(value)
    }
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    formatter.locale = Locale(identifier: "en_US")
    return "$" + (formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value))
}

// MARK: - Versions and updates

/// Compares semantic versions like "0.3.1", "v1.24.0", "1.21.0-beta.3". A release sorts after its prereleases.
func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
    func split(_ value: String) -> (core: [Int], pre: [String]) {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") {
            text.removeFirst()
        }
        text = String(text.split(separator: "+", maxSplits: 1).first ?? "")
        let parts = text.split(separator: "-", maxSplits: 1).map(String.init)
        let core = (parts.first ?? "").split(separator: ".").map { Int($0) ?? 0 }
        let pre = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
        return (core, pre)
    }
    let a = split(lhs), b = split(rhs)
    for index in 0..<max(a.core.count, b.core.count, 3) {
        let x = index < a.core.count ? a.core[index] : 0
        let y = index < b.core.count ? b.core[index] : 0
        if x != y {
            return x < y ? .orderedAscending : .orderedDescending
        }
    }
    switch (a.pre.isEmpty, b.pre.isEmpty) {
    case (true, true):
        return .orderedSame
    case (true, false):
        return .orderedDescending
    case (false, true):
        return .orderedAscending
    case (false, false):
        for index in 0..<max(a.pre.count, b.pre.count) {
            guard index < a.pre.count else { return .orderedAscending }
            guard index < b.pre.count else { return .orderedDescending }
            let x = a.pre[index], y = b.pre[index]
            if x == y { continue }
            if let xi = Int(x), let yi = Int(y) {
                return xi < yi ? .orderedAscending : .orderedDescending
            }
            return x < y ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }
}

func isNewerVersion(_ candidate: String, than current: String) -> Bool {
    compareVersions(candidate, current) == .orderedDescending
}

/// Highest version among `tags` (prereleases included when they are passed in), so a release list
/// can be scanned without trusting GitHub's ordering.
func newestVersionTag(_ tags: [String]) -> String? {
    tags.reduce(nil) { best, tag in
        guard let best else {
            return tag
        }
        return isNewerVersion(tag, than: best) ? tag : best
    }
}

/// Release asset the updater installs: the versioned DMG produced by build-dmg.sh.
func isAppUpdateAsset(_ name: String) -> Bool {
    name.hasPrefix("CodexLBStatusBar-") && name.hasSuffix(".dmg")
}

/// Parses GitHub's `digest` field ("sha256:<hex>").
func sha256FromDigest(_ digest: String?) -> String? {
    guard let digest, digest.lowercased().hasPrefix("sha256:") else {
        return nil
    }
    let hex = String(digest.dropFirst(7)).lowercased()
    return hex.count == 64 && hex.allSatisfy(\.isHexDigit) ? hex : nil
}

/// Refuses installs from locations that can't be replaced in place (mounted DMG, Gatekeeper translocation).
func canSelfUpdate(bundlePath: String) -> Bool {
    bundlePath.hasSuffix(".app") && !bundlePath.hasPrefix("/Volumes/") && !bundlePath.contains("/AppTranslocation/")
}

// MARK: - Appearance

enum AppTheme: String, CaseIterable {
    case system
    case light
    case dark

    var title: String {
        switch self {
        case .system:
            return "System"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
    }
}

/// Maps the 0...1 brightness setting (0.5 = default) to a multiplier for surface fills
/// (cards, tracks, chart bars): 0 -> 0.4x (dimmer), 0.5 -> 1x, 1 -> 2.2x (brighter).
func surfaceIntensity(brightness: Double) -> Double {
    let value = min(max(brightness, 0), 1)
    return value <= 0.5 ? 0.4 + value * 1.2 : 1 + (value - 0.5) * 2.4
}

enum UsageChartStyle: String, CaseIterable {
    case bars
    case line
    case area

    var title: String {
        switch self {
        case .bars:
            return "Bars"
        case .line:
            return "Line"
        case .area:
            return "Area"
        }
    }
}

/// Menu label for the current dashboard session, or nil when signed out.
func sessionMenuLabel(authenticated: Bool, role: String?) -> String? {
    guard authenticated else {
        return nil
    }
    switch role {
    case "admin":
        return "Signed in as Admin"
    case "guest":
        return "Signed in as Guest"
    default:
        return "Signed in"
    }
}

// MARK: - Account list sort and filter

enum AccountSortOrder: String, CaseIterable {
    case status
    case remaining
    case resetSoonest
    case name

    var title: String {
        switch self {
        case .status:
            return "Status"
        case .remaining:
            return "Remaining"
        case .resetSoonest:
            return "Reset soonest"
        case .name:
            return "Name"
        }
    }

    var next: AccountSortOrder {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

enum AccountFilter: String, CaseIterable {
    case all
    case attention

    var title: String {
        switch self {
        case .all:
            return "All accounts"
        case .attention:
            return "Needs attention"
        }
    }
}

/// Minimal account facts for ordering, decoupled from the Decodable model so it can be tested.
struct AccountSortKey {
    let id: String
    let name: String
    let status: String
    let primaryRemaining: Double?
    let secondaryRemaining: Double?
    let primaryResetAt: Date?
    let secondaryResetAt: Date?

    /// The window that limits the account right now (lowest remaining).
    var bottleneckRemaining: Double? {
        [primaryRemaining, secondaryRemaining].compactMap { $0 }.min()
    }

    var bottleneckResetAt: Date? {
        switch (primaryRemaining, secondaryRemaining) {
        case let (p?, s?):
            return p <= s ? primaryResetAt ?? secondaryResetAt : secondaryResetAt ?? primaryResetAt
        case (_?, nil):
            return primaryResetAt
        case (nil, _?):
            return secondaryResetAt
        default:
            return [primaryResetAt, secondaryResetAt].compactMap { $0 }.min()
        }
    }

    /// Anything the operator may want to look at: not serving normally, or nearly out.
    var needsAttention: Bool {
        status != "active" || (bottleneckRemaining ?? 100) < 30
    }
}

private func statusRank(_ status: String) -> Int {
    switch status {
    case "active":
        return 0
    case "rate_limited", "quota_exceeded":
        return 1
    case "paused":
        return 2
    default:
        return 3
    }
}

/// Returns account ids in display order after filtering.
func orderedAccountIDs(_ keys: [AccountSortKey], sort: AccountSortOrder, filter: AccountFilter) -> [String] {
    let filtered = filter == .attention ? keys.filter(\.needsAttention) : keys
    func byName(_ a: AccountSortKey, _ b: AccountSortKey) -> Bool {
        a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
    let sorted = filtered.sorted { a, b in
        switch sort {
        case .status:
            let ra = statusRank(a.status), rb = statusRank(b.status)
            return ra != rb ? ra < rb : byName(a, b)
        case .remaining:
            // Most headroom first; accounts without data last.
            let x = a.bottleneckRemaining ?? -1, y = b.bottleneckRemaining ?? -1
            return x != y ? x > y : byName(a, b)
        case .resetSoonest:
            let x = a.bottleneckResetAt ?? .distantFuture, y = b.bottleneckResetAt ?? .distantFuture
            return x != y ? x < y : byName(a, b)
        case .name:
            return byName(a, b)
        }
    }
    return sorted.map(\.id)
}

// MARK: - Reset credit expiry alerts

let resetCreditExpiryWarning: TimeInterval = 24 * 3_600

/// Stable key per credit batch, so each upcoming expiry alerts once.
func resetCreditExpiryAlertKey(accountId: String, expiresAt: Date) -> String {
    "\(accountId)|\(Int(expiresAt.timeIntervalSince1970))"
}

/// True when unused credits expire within the warning window (and haven't expired yet).
func resetCreditExpiresSoon(count: Int, expiresAt: Date?, now: Date = Date()) -> Bool {
    guard count > 0, let expiresAt else {
        return false
    }
    let remaining = expiresAt.timeIntervalSince(now)
    return remaining > 0 && remaining <= resetCreditExpiryWarning
}

// MARK: - Offline

/// "Offline · data from 5m ago" style caption for stale data after a failed refresh.
func staleDataLabel(lastSuccess: Date?, now: Date = Date()) -> String {
    guard let lastSuccess else {
        return "Offline"
    }
    let seconds = max(0, Int(now.timeIntervalSince(lastSuccess)))
    if seconds < 60 {
        return "Offline · data from just now"
    }
    return "Offline · data from \(elapsedTime(since: lastSuccess, now: now)) ago"
}
