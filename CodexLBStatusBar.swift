import Cocoa
import Foundation
import Security
import ServiceManagement
import UserNotifications

private let defaultBaseURL = "http://127.0.0.1:2455"
private let appDisplayName = "Codex LB Status"
private let serverVersionMenuItemIdentifier = NSUserInterfaceItemIdentifier("codexLBServerVersion")

private enum SavedLoginRole: String {
    case admin
    case guest
}

private final class SettingsStore {
    private let defaults = UserDefaults.standard
    private let baseURLKey = "codexLBBaseURL"
    private let notificationsKey = "codexLBNotificationsEnabled"
    private let colorModeKey = "codexLBStatusBarColorMode"
    private let loginRolesKey = "codexLBLoginRolesByURL"
    private let styleKey = "codexLBStatusBarStyle"
    private let showPrimaryKey = "codexLBStatusBarShowPrimary"
    private let showSecondaryKey = "codexLBStatusBarShowSecondary"
    private let showCountKey = "codexLBStatusBarShowAccountCount"
    private let showUsageKey = "codexLBShowUsageSummary"
    private let usagePeriodKey = "codexLBUsagePeriod"
    private let autoUpdateKey = "codexLBAutoCheckUpdates"
    private let themeKey = "codexLBTheme"
    private let chartStyleKey = "codexLBUsageChartStyle"
    private let sortKey = "codexLBAccountSort"
    private let filterKey = "codexLBAccountFilter"
    private let hotKeyKey = "codexLBGlobalHotKey"
    private let creditAlertKey = "codexLBCreditExpiryAlerted"

    var accountSort: AccountSortOrder {
        get { defaults.string(forKey: sortKey).flatMap(AccountSortOrder.init(rawValue:)) ?? .status }
        set { defaults.set(newValue.rawValue, forKey: sortKey) }
    }

    var accountFilter: AccountFilter {
        get { defaults.string(forKey: filterKey).flatMap(AccountFilter.init(rawValue:)) ?? .all }
        set { defaults.set(newValue.rawValue, forKey: filterKey) }
    }

    var globalHotKeyEnabled: Bool {
        get { defaults.object(forKey: hotKeyKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: hotKeyKey) }
    }

    /// Credit batches already warned about (see `resetCreditExpiryAlertKey`); pruned to the last 200.
    var alertedCreditExpiries: [String] {
        get { defaults.stringArray(forKey: creditAlertKey) ?? [] }
        set { defaults.set(Array(newValue.suffix(200)), forKey: creditAlertKey) }
    }

    var usageChartStyle: UsageChartStyle {
        get { defaults.string(forKey: chartStyleKey).flatMap(UsageChartStyle.init(rawValue:)) ?? .area }
        set { defaults.set(newValue.rawValue, forKey: chartStyleKey) }
    }
    private let brightnessKey = "codexLBBrightness"

    var theme: AppTheme {
        get { defaults.string(forKey: themeKey).flatMap(AppTheme.init(rawValue:)) ?? .system }
        set { defaults.set(newValue.rawValue, forKey: themeKey) }
    }

    /// 0...1, 0.5 is the default look.
    var brightness: Double {
        get { defaults.object(forKey: brightnessKey) as? Double ?? 0.5 }
        set { defaults.set(min(max(newValue, 0), 1), forKey: brightnessKey) }
    }
    private let skippedVersionKey = "codexLBSkippedAppVersion"
    private let notifiedServerVersionKey = "codexLBNotifiedServerVersion"

    var autoCheckUpdates: Bool {
        get { defaults.object(forKey: autoUpdateKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: autoUpdateKey) }
    }

    var skippedAppVersion: String? {
        get { defaults.string(forKey: skippedVersionKey) }
        set { defaults.set(newValue, forKey: skippedVersionKey) }
    }

    /// Latest codex-lb server version we've already notified about, so each release alerts once.
    var notifiedServerVersion: String? {
        get { defaults.string(forKey: notifiedServerVersionKey) }
        set { defaults.set(newValue, forKey: notifiedServerVersionKey) }
    }

    var statusBarStyle: StatusBarStyle {
        get { defaults.string(forKey: styleKey).flatMap(StatusBarStyle.init(rawValue:)) ?? .text }
        set { defaults.set(newValue.rawValue, forKey: styleKey) }
    }

    var statusBarItems: StatusBarItems {
        get {
            StatusBarItems(
                primary: defaults.object(forKey: showPrimaryKey) as? Bool ?? true,
                secondary: defaults.object(forKey: showSecondaryKey) as? Bool ?? true,
                accountCount: defaults.object(forKey: showCountKey) as? Bool ?? true
            )
        }
        set {
            defaults.set(newValue.primary, forKey: showPrimaryKey)
            defaults.set(newValue.secondary, forKey: showSecondaryKey)
            defaults.set(newValue.accountCount, forKey: showCountKey)
        }
    }

    var showUsageSummary: Bool {
        get { defaults.object(forKey: showUsageKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: showUsageKey) }
    }

    var usagePeriod: UsagePeriod {
        get { defaults.string(forKey: usagePeriodKey).flatMap(UsagePeriod.init(rawValue:)) ?? .week }
        set { defaults.set(newValue.rawValue, forKey: usagePeriodKey) }
    }

    var baseURLString: String {
        get {
            defaults.string(forKey: baseURLKey) ?? defaultBaseURL
        }
        set {
            defaults.set(Self.normalizedBaseURL(newValue), forKey: baseURLKey)
        }
    }

    /// Defaults to warnings-only: plain text unless something needs attention.
    var statusBarColorMode: StatusBarColorMode {
        get {
            defaults.string(forKey: colorModeKey).flatMap(StatusBarColorMode.init(rawValue:)) ?? .warningsOnly
        }
        set {
            defaults.set(newValue.rawValue, forKey: colorModeKey)
        }
    }

    /// Defaults to on; stored explicitly once the user toggles it.
    var notificationsEnabled: Bool {
        get {
            defaults.object(forKey: notificationsKey) as? Bool ?? true
        }
        set {
            defaults.set(newValue, forKey: notificationsKey)
        }
    }

    var baseURL: URL {
        URL(string: baseURLString) ?? URL(string: defaultBaseURL)!
    }

    func loginRole(for baseURL: String) -> SavedLoginRole {
        let roles = defaults.dictionary(forKey: loginRolesKey)
        return SavedLoginRole(rawValue: roles?[baseURL] as? String ?? "") ?? .admin
    }

    func setLoginRole(_ role: SavedLoginRole, for baseURL: String) {
        var roles = defaults.dictionary(forKey: loginRolesKey) ?? [:]
        roles[baseURL] = role.rawValue
        defaults.set(roles, forKey: loginRolesKey)
    }

    private static func normalizedBaseURL(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return defaultBaseURL
        }
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

private enum DashboardPasswordStore {
    private static func query(for role: SavedLoginRole, baseURL: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "local.codex-lb.statusbar.\(role.rawValue)-password",
            kSecAttrAccount as String: baseURL
        ]
    }

    static func read(_ role: SavedLoginRole, for baseURL: String) -> String? {
        let lookup = query(for: role, baseURL: baseURL).merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]) { _, new in new }
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ password: String, role: SavedLoginRole, for baseURL: String) -> OSStatus {
        let query = query(for: role, baseURL: baseURL)
        let attributes: [String: Any] = [kSecValueData as String: Data(password.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            return SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        return status
    }

    /// Attribute-only lookup: doesn't read the secret, so it never triggers a Keychain access prompt.
    static func hasAny(for baseURL: String) -> Bool {
        [SavedLoginRole.admin, .guest].contains { role in
            let lookup = query(for: role, baseURL: baseURL).merging([
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]) { _, new in new }
            return SecItemCopyMatching(lookup as CFDictionary, nil) == errSecSuccess
        }
    }

    static func delete(_ role: SavedLoginRole, for baseURL: String) -> OSStatus {
        let status = SecItemDelete(query(for: role, baseURL: baseURL) as CFDictionary)
        return status == errSecItemNotFound ? errSecSuccess : status
    }
}

private enum ClientError: LocalizedError {
    case invalidURL(String)
    case unauthorized
    case server(statusCode: Int, body: String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        case .unauthorized:
            return "Dashboard login required"
        case .server(let statusCode, let body):
            if body.isEmpty {
                return "Server returned HTTP \(statusCode)"
            }
            return "Server returned HTTP \(statusCode): \(body)"
        case .transport(let message):
            return message
        }
    }
}

private struct AuthSession: Decodable {
    let authenticated: Bool
    let passwordRequired: Bool
    let totpRequiredOnLogin: Bool
    let guestAccessEnabled: Bool
    let guestPasswordRequired: Bool
    let role: String
}

private struct DashboardOverview: Decodable {
    let lastSyncAt: Date?
    let accounts: [AccountSummary]
    // Optional so an older/newer server shape never breaks the account list.
    let summary: OverviewSummary?
    let trends: OverviewTrends?
}

private struct AccountAliasResponse: Decodable {
    let accountId: String
    let alias: String?
}

private struct AccountLimitWarmupResponse: Decodable {
    let status: String
    let enabled: Bool
}

private struct LogoutResponse: Decodable {
    let status: String?
}

private struct RuntimeVersion: Decodable {
    let currentVersion: String
    let latestVersion: String?
    let updateAvailable: Bool?
    let releaseUrl: String?
}

private struct OverviewSummary: Decodable {
    let cost: OverviewCost?
    let metrics: OverviewMetrics?
}

private struct OverviewCost: Decodable {
    let currency: String?
    let totalUsd: Double?
}

private struct OverviewMetrics: Decodable {
    let requests: Int?
    let tokens: Int?
    let cachedInputTokens: Int?
    let errorRate: Double?
}

private struct OverviewTrends: Decodable {
    let tokens: [TrendPoint]?
    let cost: [TrendPoint]?
}

private struct TrendPoint: Decodable {
    let t: Date
    let v: Double
}

private struct AccountSummary: Decodable {
    let accountId: String
    let email: String
    let alias: String?
    let displayName: String
    let planType: String
    let routingPolicy: String
    let status: String
    let usage: AccountUsage?
    let resetAtPrimary: Date?
    let resetAtSecondary: Date?
    let resetAtMonthly: Date?
    let windowMinutesPrimary: Int?
    let windowMinutesSecondary: Int?
    let windowMinutesMonthly: Int?
    let lastRefreshAt: Date?
    let deactivationReason: String?
    let securityWorkAuthorized: Bool?
    let limitWarmupEnabled: Bool?
    let limitWarmup: AccountLimitWarmupStatus?
    let availableResetCredits: Int?
    let resetCreditNearestExpiresAt: Date?
}

private struct AccountUsage: Decodable {
    let primaryRemainingPercent: Double?
    let secondaryRemainingPercent: Double?
    let monthlyRemainingPercent: Double?
}

private struct AccountLimitWarmupStatus: Decodable {
    let window: String
    let status: String
    let model: String
    let attemptedAt: Date
    let completedAt: Date?
}

private struct AccountActionResponse: Decodable {
    let status: String
}

private struct AccountRoutingPolicyUpdateResponse: Decodable {
    let accountId: String
    let routingPolicy: String
}

private struct ResetCreditItem: Decodable {
    let id: String
    let status: String?
    let expiresAt: Date?
}

private struct ResetCreditsSnapshot: Decodable {
    let availableCount: Int
    let nearestExpiresAt: Date?
    let credits: [ResetCreditItem]
}

private struct ResetCreditConsumeResponse: Decodable {
    let code: String?
    let windowsReset: Int?
    let redeemedAt: Date?
}

private struct OAuthStartResponse: Decodable {
    let flowId: String?
    let method: String
    let authorizationUrl: String?
    let callbackUrl: String?
    let verificationUrl: String?
    let userCode: String?
    let deviceAuthId: String?
    let intervalSeconds: Int?
    let expiresInSeconds: Int?
}

private struct OAuthStatusResponse: Decodable {
    let status: String
    let errorMessage: String?
}

private struct OAuthCompleteResponse: Decodable {
    let status: String
}

private struct OAuthManualCallbackResponse: Decodable {
    let status: String
    let errorMessage: String?
}

private enum AccountMutation {
    case pause
    case reactivate
    case routingPolicy(String)
    case alias(String?)
    case limitWarmup(Bool)
    case resetCredit
    case reauth
}

private final class CodexLBClient {
    private let settings: SettingsStore
    private let session: URLSession
    private let decoder: JSONDecoder
    private(set) var serverVersion: String?

    init(settings: SettingsStore) {
        self.settings = settings
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.timeoutIntervalForRequest = 10
        self.session = URLSession(configuration: configuration)
        self.decoder = JSONDecoder.codexLBDecoder()
    }

    func getSession() async throws -> AuthSession {
        try await request(path: "/api/dashboard-auth/session")
    }

    func fetchOverview() async throws -> DashboardOverview {
        try await request(path: "/api/dashboard/overview?timeframe=\(settings.usagePeriod.rawValue)")
    }

    /// codex-lb's own update check (`/api/runtime/version`). Older servers may not have it.
    func getRuntimeVersion() async throws -> RuntimeVersion {
        try await request(path: "/api/runtime/version")
    }

    func loginPassword(_ password: String) async throws -> AuthSession {
        let payload = try JSONSerialization.data(withJSONObject: ["password": password], options: [])
        return try await request(path: "/api/dashboard-auth/password/login", method: "POST", body: payload)
    }

    func setAlias(accountId: String, alias: String?) async throws {
        let payload = try JSONSerialization.data(withJSONObject: ["alias": alias as Any? ?? NSNull()], options: [])
        let _: AccountAliasResponse = try await request(
            path: "/api/accounts/\(encodedPathComponent(accountId))/alias", method: "PUT", body: payload)
    }

    func setLimitWarmup(accountId: String, enabled: Bool) async throws {
        let payload = try JSONSerialization.data(withJSONObject: ["enabled": enabled], options: [])
        let _: AccountLimitWarmupResponse = try await request(
            path: "/api/accounts/\(encodedPathComponent(accountId))/limit-warmup", method: "PUT", body: payload)
    }

    func logout() async throws {
        let _: LogoutResponse = try await request(path: "/api/dashboard-auth/logout", method: "POST")
    }

    func loginGuest(password: String?) async throws -> AuthSession {
        let body: Data?
        if let password, !password.isEmpty {
            body = try JSONSerialization.data(withJSONObject: ["password": password], options: [])
        } else {
            body = nil
        }
        return try await request(path: "/api/dashboard-auth/guest/login", method: "POST", body: body)
    }

    func verifyTotp(_ code: String) async throws -> AuthSession {
        let payload = try JSONSerialization.data(withJSONObject: ["code": code], options: [])
        return try await request(path: "/api/dashboard-auth/totp/verify", method: "POST", body: payload)
    }

    func pauseAccount(_ accountId: String) async throws {
        let _: AccountActionResponse = try await request(path: "/api/accounts/\(encodedPathComponent(accountId))/pause", method: "POST")
    }

    func reactivateAccount(_ accountId: String) async throws {
        let _: AccountActionResponse = try await request(path: "/api/accounts/\(encodedPathComponent(accountId))/reactivate", method: "POST")
    }

    func updateRoutingPolicy(accountId: String, routingPolicy: String) async throws {
        let payload = try JSONSerialization.data(withJSONObject: ["routingPolicy": routingPolicy], options: [])
        let _: AccountRoutingPolicyUpdateResponse = try await request(
            path: "/api/accounts/\(encodedPathComponent(accountId))/routing-policy",
            method: "PUT",
            body: payload
        )
    }

    /// Returns `nil` when the server has no cached reset-credit snapshot for the account yet.
    func getResetCredits(_ accountId: String) async throws -> ResetCreditsSnapshot? {
        try await request(path: "/api/accounts/\(encodedPathComponent(accountId))/rate-limit-reset-credits")
    }

    /// `redeemRequestId` makes the consume idempotent: retrying with the same id reuses the server-side pin.
    func consumeResetCredit(_ accountId: String, redeemRequestId: String) async throws -> ResetCreditConsumeResponse {
        let payload = try JSONSerialization.data(withJSONObject: ["redeemRequestId": redeemRequestId], options: [])
        return try await request(
            path: "/api/accounts/\(encodedPathComponent(accountId))/rate-limit-reset-credits/consume",
            method: "POST",
            body: payload
        )
    }

    /// Starts a targeted re-authentication flow for an existing account. `method` is "browser" or "device".
    func startOAuth(method: String, accountId: String) async throws -> OAuthStartResponse {
        let payload = try JSONSerialization.data(withJSONObject: ["forceMethod": method, "accountId": accountId], options: [])
        return try await request(path: "/api/oauth/start", method: "POST", body: payload)
    }

    func oauthStatus(flowId: String?) async throws -> OAuthStatusResponse {
        var path = "/api/oauth/status"
        if let flowId, let encoded = flowId.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) {
            path += "?flowId=\(encoded)"
        }
        return try await request(path: path)
    }

    @discardableResult
    func completeOAuth(flowId: String?, deviceAuthId: String?, userCode: String?) async throws -> OAuthCompleteResponse {
        var body: [String: String] = [:]
        body["flowId"] = flowId
        body["deviceAuthId"] = deviceAuthId
        body["userCode"] = userCode
        let payload = try JSONSerialization.data(withJSONObject: body, options: [])
        return try await request(path: "/api/oauth/complete", method: "POST", body: payload)
    }

    func submitOAuthCallback(_ callbackURL: String, flowId: String?) async throws -> OAuthManualCallbackResponse {
        var body: [String: String] = ["callbackUrl": callbackURL]
        body["flowId"] = flowId
        let payload = try JSONSerialization.data(withJSONObject: body, options: [])
        return try await request(path: "/api/oauth/manual-callback", method: "POST", body: payload)
    }

    private func request<T: Decodable>(path: String, method: String = "GET", body: Data? = nil) async throws -> T {
        let url = try endpoint(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ClientError.transport("Unexpected non-HTTP response")
            }
            serverVersion = httpResponse.value(forHTTPHeaderField: "X-App-Version")
            if httpResponse.statusCode == 401 {
                throw ClientError.unauthorized
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw ClientError.server(
                    statusCode: httpResponse.statusCode,
                    body: dashboardErrorMessage(from: data) ?? String(data: data.prefix(300), encoding: .utf8) ?? ""
                )
            }
            return try decoder.decode(T.self, from: data)
        } catch let error as ClientError {
            throw error
        } catch {
            throw ClientError.transport(error.localizedDescription)
        }
    }

    private func endpoint(_ path: String) throws -> URL {
        let base = settings.baseURLString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let raw = "\(base)/\(suffix)"
        guard let url = URL(string: raw) else {
            throw ClientError.invalidURL(raw)
        }
        return url
    }
}

private extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#?")
        return allowed
    }()
}

private func encodedPathComponent(_ value: String) -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/?#")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}

private extension JSONDecoder {
    static func codexLBDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = DateFormatters.iso8601Fractional.date(from: value) {
                return date
            }
            if let date = DateFormatters.iso8601.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO-8601 date: \(value)")
        }
        return decoder
    }
}

private enum DateFormatters {
    static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let shortDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()

    static let dateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static let timeOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}

/// One palette for every custom view. Semantic colors adapt to light/dark and let the native
/// menu material show through, so the panels read as part of the menu instead of a pasted-in card.
private enum VisualStyle {
    static let menuWidth: CGFloat = 400
    static let inset: CGFloat = 14
    static let contentWidth: CGFloat = menuWidth - inset * 2
    static let accountCardHeight: CGFloat = 146
    static let cardRadius: CGFloat = 10
    static let cardPadding: CGFloat = 12
    static let sectionHeaderHeight: CGFloat = 30

    static let panelBackground = NSColor.clear
    /// Set from Settings > Brightness; scales the neutral surfaces below (cards, tracks, chart).
    static var intensity: CGFloat = 1

    static var cardBackground: NSColor { NSColor.labelColor.withAlphaComponent(min(0.05 * intensity, 0.2)) }
    static var border: NSColor { NSColor.labelColor.withAlphaComponent(min(0.08 * intensity, 0.25)) }
    static let textPrimary = NSColor.labelColor
    static let textSecondary = NSColor.secondaryLabelColor
    static let textMuted = NSColor.tertiaryLabelColor
    static var track: NSColor { NSColor.labelColor.withAlphaComponent(min(0.10 * intensity, 0.3)) }
    static var trackDim: NSColor { NSColor.labelColor.withAlphaComponent(min(0.07 * intensity, 0.22)) }
    static let green = NSColor.systemGreen
    static let greenDim = NSColor.systemGreen.withAlphaComponent(0.16)
    static let amber = NSColor.systemOrange
    static let amberDim = NSColor.systemOrange.withAlphaComponent(0.16)
    static let red = NSColor.systemRed
    static let redDim = NSColor.systemRed.withAlphaComponent(0.16)
    static let blue = NSColor.controlAccentColor
    static let blueDim = NSColor.controlAccentColor.withAlphaComponent(0.16)
    static var chart: NSColor { NSColor.labelColor.withAlphaComponent(min(0.18 + 0.1 * intensity, 0.6)) }
    static var labelWash: NSColor { NSColor.labelColor.withAlphaComponent(min(0.07 * intensity, 0.22)) }
}

private extension NSColor {
    /// Layer colors are static CGColors, so resolve dynamic colors against the app's current appearance.
    var resolvedCG: CGColor {
        var result = cgColor
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            result = self.cgColor
        }
        return result
    }
}

private class RoundedPanelView: NSView {
    init(width: CGFloat, height: CGFloat, background: NSColor = VisualStyle.panelBackground) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        wantsLayer = true
        layer?.backgroundColor = background.resolvedCG
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

private final class DotView: NSView {
    private let color: NSColor

    init(color: NSColor, size: CGFloat = 7) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = color.resolvedCG
        layer?.cornerRadius = size / 2
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

private final class BadgeView: NSButton {
    enum Tone {
        case neutral
        case active
        case warning
        case danger
        case burnFirst
        case preserve

        /// Tinted pill: accent text on a faint wash of the same accent, no hard border.
        private var accent: NSColor {
            switch self {
            case .neutral:
                return VisualStyle.textSecondary
            case .active:
                return VisualStyle.green
            case .warning, .burnFirst:
                return VisualStyle.amber
            case .danger:
                return VisualStyle.red
            case .preserve:
                return VisualStyle.blue
            }
        }

        var background: NSColor {
            self == .neutral ? VisualStyle.labelWash : accent.withAlphaComponent(0.14)
        }

        var border: NSColor {
            self == .neutral ? VisualStyle.border : accent.withAlphaComponent(0.22)
        }

        var text: NSColor {
            accent
        }
    }

    let accountId: String?
    let currentValue: String?
    private let tone: Tone
    private var hoverTrackingArea: NSTrackingArea?

    init(
        text: String,
        tone: Tone,
        dot: Bool = false,
        symbolName: String? = nil,
        accountId: String? = nil,
        currentValue: String? = nil,
        target: AnyObject? = nil,
        action: Selector? = nil,
        enabled: Bool = true,
        busy: Bool = false
    ) {
        self.accountId = accountId
        self.currentValue = currentValue
        self.tone = tone
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        title = ""
        self.target = target
        self.action = action
        isEnabled = enabled
        alphaValue = busy ? 0.55 : 1
        setAccessibilityLabel(text)
        wantsLayer = true
        layer?.backgroundColor = tone.background.resolvedCG
        layer?.borderColor = tone.border.resolvedCG
        layer?.borderWidth = 1
        layer?.cornerRadius = 11

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        var markerWidth: CGFloat = 0
        if let symbolName {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            image.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: text)
            image.contentTintColor = tone.text
            image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            NSLayoutConstraint.activate([
                image.widthAnchor.constraint(equalToConstant: 11),
                image.heightAnchor.constraint(equalToConstant: 11),
            ])
            stack.addArrangedSubview(image)
            markerWidth = 16
        } else if dot {
            stack.addArrangedSubview(DotView(color: tone.text, size: 6))
            markerWidth = 11
        }
        let label = makeLabel(text, size: 11, weight: .medium, color: tone.text)
        stack.addArrangedSubview(label)
        let leadingPadding: CGFloat = markerWidth > 0 ? 8 : 10
        let contentWidth = label.intrinsicContentSize.width + leadingPadding + markerWidth + 10

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            widthAnchor.constraint(equalToConstant: ceil(contentWidth)),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingPadding),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else {
            return
        }
        layer?.borderWidth = 1
        layer?.borderColor = tone.text.withAlphaComponent(0.5).resolvedCG
        layer?.backgroundColor = tone.text.withAlphaComponent(0.24).resolvedCG
    }

    override func mouseExited(with event: NSEvent) {
        layer?.borderWidth = 1
        layer?.borderColor = tone.border.resolvedCG
        layer?.backgroundColor = tone.background.resolvedCG
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else {
            return
        }
        alphaValue = 0.68
        super.mouseDown(with: event)
        alphaValue = 1
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

/// Reset-credit action in the card footer. Reads as a link at rest and becomes a tinted pill on hover.
private final class ResetCreditButton: NSButton {
    let accountId: String
    private var hoverTrackingArea: NSTrackingArea?

    init(text: String, accountId: String, target: AnyObject, action: Selector, enabled: Bool, busy: Bool) {
        self.accountId = accountId
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        setButtonType(.momentaryChange)
        self.target = target
        self.action = action
        isEnabled = enabled
        alphaValue = busy ? 0.55 : 1
        wantsLayer = true
        layer?.cornerRadius = 9
        let color = enabled ? VisualStyle.blue : VisualStyle.textMuted
        let symbol = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: nil)
        image = symbol?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        imagePosition = .imageLeading
        imageHugsTitle = true
        contentTintColor = color
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: color,
        ])
        setAccessibilityLabel(text)
        heightAnchor.constraint(equalToConstant: 18).isActive = true
    }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 12, height: 18)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else {
            return
        }
        layer?.backgroundColor = VisualStyle.blue.withAlphaComponent(0.16).resolvedCG
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

private final class QuotaProgressView: NSView {
    private let percent: Double?
    private let paceMarker: Double?

    /// `paceMarker`: remaining percent expected at an even burn rate, drawn as a tick.
    init(percent: Double?, paceMarker: Double? = nil) {
        self.percent = percent
        self.paceMarker = paceMarker
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 8)
    }

    override func draw(_ dirtyRect: NSRect) {
        // 5pt bar centered in 8pt so the pace tick can overhang without clipping.
        let rect = NSRect(x: bounds.minX, y: bounds.midY - 2.5, width: bounds.width, height: 5)
        let track = NSBezierPath(roundedRect: rect, xRadius: 2.5, yRadius: 2.5)
        VisualStyle.track.setFill()
        track.fill()

        guard let percent else {
            return
        }
        let clamped = min(max(percent, 0), 100)
        guard clamped > 0 else {
            drawPaceMarker(in: rect)
            return
        }
        let fillWidth = max(5, rect.width * CGFloat(clamped / 100))
        let fillRect = NSRect(x: rect.minX, y: rect.minY, width: min(fillWidth, rect.width), height: rect.height)
        let fill = NSBezierPath(roundedRect: fillRect, xRadius: 2.5, yRadius: 2.5)
        quotaColor(percent).setFill()
        fill.fill()
        drawPaceMarker(in: rect)
    }

    private func drawPaceMarker(in rect: NSRect) {
        guard let paceMarker else {
            return
        }
        let x = rect.minX + rect.width * CGFloat(min(max(paceMarker, 0), 100) / 100)
        VisualStyle.textPrimary.withAlphaComponent(0.55).setFill()
        let tick = NSRect(x: min(max(x - 0.75, rect.minX), rect.maxX - 1.5), y: bounds.minY, width: 1.5, height: bounds.height)
        NSBezierPath(roundedRect: tick, xRadius: 0.75, yRadius: 0.75).fill()
    }
}

private final class QuotaMiniView: NSView {
    init(label: String, remainingPercent: Double?, resetAt: Date?, windowMinutes: Int?) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let pace = remainingPercent.flatMap { quotaPace(remainingPercent: $0, resetAt: resetAt, windowMinutes: windowMinutes) }
        let name = makeLabel(label, size: 12, weight: .medium, color: VisualStyle.textSecondary)
        let percent = makeLabel(formatOptionalPercent(remainingPercent), size: 12, weight: .semibold, color: VisualStyle.textPrimary)
        percent.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let topRow = Self.row(name, percent)

        let progress = QuotaProgressView(percent: remainingPercent, paceMarker: pace?.expectedRemainingPercent)
        let resetText = resetAt.map { "Resets in \(relativeTime($0))" } ?? "No reset time"
        let reset = makeLabel(resetText, size: 11, color: VisualStyle.textMuted)
        // Right side: the one thing worth knowing. Runway when it won't last, otherwise the pace.
        let paceText: String
        var paceColor = VisualStyle.textMuted
        if let pace, pace.exhausted {
            paceText = "Empty until reset"
            paceColor = VisualStyle.red
        } else if let pace, pace.runsOutIn != nil {
            paceText = pace.runwayLabel
            paceColor = VisualStyle.amber
        } else {
            paceText = pace?.paceLabel ?? ""
        }
        let paceLabel = makeLabel(paceText, size: 11, weight: paceColor == VisualStyle.textMuted ? .regular : .medium, color: paceColor)
        let detailRow = Self.row(reset, paceLabel)

        let stack = NSStackView(views: [topRow, progress, detailRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        if let pace {
            toolTip = "\(pace.paceLabel) · \(pace.runwayLabel)\nThe tick marks where remaining quota would be at an even pace."
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            topRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progress.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private static func row(_ left: NSTextField, _ right: NSTextField) -> NSStackView {
        right.alignment = .right
        right.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        left.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [left, NSView.spacer(), right])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

private final class AccountCardView: NSView {
    private let accountId: String
    private let contextMenuProvider: (String) -> NSMenu?

    /// Right-click (or Control-click) anywhere on the card opens the account actions menu.
    override func rightMouseDown(with event: NSEvent) {
        showContextMenu(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            showContextMenu(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }

    private func showContextMenu(with event: NSEvent) {
        _ = contextMenuProvider(accountId)
    }

    /// Called by the app's right-click monitor (menu tracking doesn't route rightMouseDown to views).
    func openContextMenu() {
        _ = contextMenuProvider(accountId)
    }

    init(
        account: AccountSummary,
        canWrite: Bool,
        isRefreshing: Bool,
        mutation: AccountMutation?,
        actionTarget: AnyObject,
        statusAction: Selector,
        routingAction: Selector,
        resetAction: Selector,
        contextMenuProvider: @escaping (String) -> NSMenu?
    ) {
        self.accountId = account.accountId
        self.contextMenuProvider = contextMenuProvider
        super.init(frame: NSRect(x: 0, y: 0, width: VisualStyle.contentWidth, height: VisualStyle.accountCardHeight))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = VisualStyle.cardBackground.resolvedCG
        layer?.borderColor = VisualStyle.border.resolvedCG
        layer?.borderWidth = 1
        layer?.cornerRadius = VisualStyle.cardRadius
        let controlsBusy = isRefreshing || mutation != nil
        var routingIsUpdating = false
        var statusIsUpdating = false
        var resetIsUpdating = false
        var reauthPending = false
        switch mutation {
        case .routingPolicy:
            routingIsUpdating = true
        case .pause, .reactivate:
            statusIsUpdating = true
        case .alias, .limitWarmup:
            break
        case .resetCredit:
            resetIsUpdating = true
        case .reauth:
            reauthPending = true
        case nil:
            break
        }

        let title = makeLabel(accountTitle(account), size: 13, weight: .semibold, color: VisualStyle.textPrimary)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let subtitle = makeLabel(accountSubtitle(account), size: 11, weight: .regular, color: VisualStyle.textMuted)
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let identity = NSStackView(views: [title, subtitle])
        identity.orientation = .vertical
        identity.alignment = .leading
        identity.spacing = 1
        identity.translatesAutoresizingMaskIntoConstraints = false

        let terminalStatus = accountNeedsReauthentication(account.status)
        let routingPresentation = routingBadgePresentation(account.routingPolicy)
        let routingTone: BadgeView.Tone
        switch routingPresentation.tone {
        case .neutral:
            routingTone = .neutral
        case .burnFirst:
            routingTone = .burnFirst
        case .preserve:
            routingTone = .preserve
        }
        let routing = BadgeView(
            text: routingIsUpdating ? "Updating..." : routingPresentation.label,
            tone: routingTone,
            symbolName: routingIsUpdating ? "arrow.triangle.2.circlepath" : routingPresentation.symbolName,
            accountId: account.accountId,
            currentValue: account.routingPolicy,
            target: actionTarget,
            action: routingAction,
            enabled: canWrite && !controlsBusy && !terminalStatus,
            busy: routingIsUpdating
        )
        routing.toolTip = canWrite && !terminalStatus ? "Change to \(routingBadgePresentation(nextRoutingPolicy(after: account.routingPolicy)).label)" : nil
        let statusPresentation = accountStatusPresentation(account.status)
        let statusTone: BadgeView.Tone
        switch statusPresentation.tone {
        case .green:
            statusTone = .active
        case .amber:
            statusTone = .warning
        case .red:
            statusTone = .danger
        }
        let statusBusy = statusIsUpdating || reauthPending
        let status = BadgeView(
            text: statusIsUpdating ? "Updating..." : reauthPending ? "Signing in..." : statusPresentation.label,
            tone: reauthPending ? .warning : statusTone,
            dot: !statusBusy && account.status == "active",
            symbolName: statusBusy ? "arrow.triangle.2.circlepath" : terminalStatus ? "person.badge.key" : nil,
            accountId: account.accountId,
            currentValue: account.status,
            target: actionTarget,
            action: statusAction,
            // A pending sign-in stays clickable so it can be resumed or cancelled.
            enabled: canWrite && (reauthPending || (!controlsBusy && (statusPresentation.canToggle || terminalStatus))),
            busy: statusIsUpdating
        )
        if canWrite && reauthPending {
            status.toolTip = "Sign-in in progress. Click to resume or cancel."
        } else if canWrite && terminalStatus {
            status.toolTip = "Re-authenticate account"
        } else if canWrite && statusPresentation.canToggle {
            status.toolTip = account.status == "active" ? "Pause account" : "Reactivate account"
        }

        var topViews: [NSView] = [identity, routing]
        if account.securityWorkAuthorized == true {
            topViews.append(shieldView())
        }
        topViews.append(status)
        let topRow = NSStackView(views: topViews)
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.distribution = .fill
        topRow.spacing = 6
        topRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topRow)

        let resetCount = account.availableResetCredits ?? 0
        let resetCreditLabel = resetCreditSummaryText(
            count: resetCount,
            expiresAt: account.resetCreditNearestExpiresAt
        ).map { label -> ResetCreditButton in
            let redeemable = canRedeemResetCredit(status: account.status, availableCount: resetCount)
            let button = ResetCreditButton(
                text: resetIsUpdating ? "Resetting..." : label,
                accountId: account.accountId,
                target: actionTarget,
                action: resetAction,
                enabled: canWrite && !controlsBusy && redeemable,
                busy: resetIsUpdating
            )
            if !canWrite {
                button.toolTip = "Admin login required to use reset credits"
            } else if !redeemable {
                button.toolTip = "Reset credits cannot be used while the account is \(statusPresentation.label.lowercased())"
            } else {
                let expiry = account.resetCreditNearestExpiresAt.map {
                    " Soonest expires \(DateFormatters.dateTime.string(from: $0))."
                } ?? ""
                button.toolTip = "Click to use a reset credit (asks for confirmation).\(expiry)"
            }
            return button
        }

        let quotaRow = NSStackView()
        quotaRow.orientation = .horizontal
        quotaRow.alignment = .top
        quotaRow.distribution = .fillEqually
        quotaRow.spacing = 16
        quotaRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(quotaRow)

        let quotaViews = quotaViewsForAccount(account)
        if quotaViews.isEmpty {
            quotaRow.addArrangedSubview(makeLabel("Quota unavailable", size: 12, color: VisualStyle.textMuted))
        } else {
            for view in quotaViews.prefix(2) {
                quotaRow.addArrangedSubview(view)
            }
        }

        let creditView: NSView = resetCreditLabel
            ?? makeLabel("No reset credits", size: 11, weight: .regular, color: VisualStyle.textMuted)
        // The hover pill has its own padding; pull it left so its text lines up with the card content.
        let creditLeading: CGFloat = resetCreditLabel == nil ? 0 : -6
        creditView.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        let warmupText = account.limitWarmupEnabled == true ? "Warm-up · \(warmupAttempt(account))" : "Warm-up off"
        let warmup = makeLabel(warmupText, size: 11, weight: .regular, color: VisualStyle.textMuted)
        warmup.alignment = .right
        warmup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let bottomRow = NSStackView(views: [creditView, NSView.spacer(), warmup])
        bottomRow.orientation = .horizontal
        bottomRow.alignment = .centerY
        bottomRow.spacing = 8
        bottomRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bottomRow)

        let divider = NSView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        divider.layer?.backgroundColor = VisualStyle.border.resolvedCG
        addSubview(divider)

        let pad = VisualStyle.cardPadding
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: VisualStyle.contentWidth),
            heightAnchor.constraint(equalToConstant: VisualStyle.accountCardHeight),
            topRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            topRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            topRow.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            quotaRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            quotaRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            quotaRow.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: 12),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            divider.heightAnchor.constraint(equalToConstant: 1),
            divider.bottomAnchor.constraint(equalTo: bottomRow.topAnchor, constant: -8),
            bottomRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad + creditLeading),
            bottomRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            bottomRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            bottomRow.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

private final class AccountsPanelView: RoundedPanelView {
    init(
        accounts: [AccountSummary],
        isRefreshing: Bool,
        lastRefreshedAt: Date?,
        refreshTarget: AnyObject,
        refreshAction: Selector,
        canWrite: Bool,
        accountMutations: [String: AccountMutation],
        accountActionTarget: AnyObject,
        statusAction: Selector,
        routingAction: Selector,
        resetAction: Selector,
        sort: AccountSortOrder,
        filter: AccountFilter,
        sortAction: Selector,
        filterAction: Selector,
        offlineSince: Date?,
        contextMenuProvider: @escaping (String) -> NSMenu?
    ) {
        let isOffline = offlineSince != nil
        let byId = Dictionary(accounts.map { ($0.accountId, $0) }, uniquingKeysWith: { first, _ in first })
        let visible = orderedAccountIDs(accounts.map(accountSortKey), sort: sort, filter: filter).compactMap { byId[$0] }
        let cardHeight = VisualStyle.accountCardHeight
        let emptyHeight: CGFloat = 56
        let gap: CGFloat = 8
        let headerHeight: CGFloat = 30
        let maxCardsVisible: CGFloat = 4
        // Header: 10 top + 20 row + 6 gap; scroll area ends 10 above the bottom. Must match the constraints
        // below exactly, or the stack overflows by a few points and the scroll view starts scrolled.
        let chrome = headerHeight + 6 + 4
        let contentHeight = visible.isEmpty
            ? chrome + emptyHeight
            : chrome + CGFloat(visible.count) * cardHeight + CGFloat(max(visible.count - 1, 0)) * gap
        let maxHeight = chrome + maxCardsVisible * cardHeight + (maxCardsVisible - 1) * gap
        let height = min(contentHeight, maxHeight)
        super.init(width: VisualStyle.menuWidth, height: height)

        let refreshControl: NSView
        if isRefreshing {
            let indicator = NSProgressIndicator()
            indicator.style = .spinning
            indicator.controlSize = .small
            indicator.translatesAutoresizingMaskIntoConstraints = false
            indicator.startAnimation(nil)
            NSLayoutConstraint.activate([
                indicator.widthAnchor.constraint(equalToConstant: 16),
                indicator.heightAnchor.constraint(equalToConstant: 16),
            ])
            refreshControl = indicator
        } else {
            let button = NSButton()
            button.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
            button.imagePosition = .imageOnly
            button.isBordered = false
            button.bezelStyle = .texturedRounded
            button.setButtonType(.momentaryPushIn)
            button.target = refreshTarget
            button.action = refreshAction
            button.translatesAutoresizingMaskIntoConstraints = false
            button.contentTintColor = VisualStyle.textMuted
            button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 22),
                button.heightAnchor.constraint(equalToConstant: 22),
            ])
            refreshControl = button
        }

        let accountCount = "\(accounts.filter { $0.status == "active" }.count)/\(accounts.count) active"
        let refreshStatus: String?
        if isRefreshing {
            refreshStatus = "Refreshing..."
        } else if isOffline {
            refreshStatus = nil
        } else {
            refreshStatus = relativeUpdatedLabel(lastRefreshedAt).map { $0.replacingOccurrences(of: "Updated ", with: "") }
        }
        let header = sectionHeader("Accounts", meta: [accountCount, refreshStatus].compactMap { $0 }.joined(separator: " · "), accessory: refreshControl)
        if isOffline, let meta = header.arrangedSubviews.last as? NSTextField {
            meta.stringValue = staleDataLabel(lastSuccess: lastRefreshedAt)
            meta.textColor = VisualStyle.amber
        }
        let sortButton = HeaderChipButton(
            title: sort.title, symbolName: "arrow.up.arrow.down", active: false, target: refreshTarget, action: sortAction)
        sortButton.toolTip = "Sort by \(sort.title.lowercased()) · click for \(sort.next.title.lowercased())"
        let filterButton = HeaderChipButton(
            title: nil,
            symbolName: filter == .attention ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle",
            active: filter == .attention, target: refreshTarget, action: filterAction)
        filterButton.toolTip = filter == .attention ? "Showing accounts that need attention · click to show all" : "Show only accounts that need attention"
        header.addArrangedSubview(sortButton)
        header.addArrangedSubview(filterButton)
        addSubview(header)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = gap
        stack.translatesAutoresizingMaskIntoConstraints = false

        if visible.isEmpty {
            let empty = makeLabel("All accounts look healthy.", size: 12, color: VisualStyle.textSecondary)
            let box = NSView()
            box.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(empty)
            NSLayoutConstraint.activate([
                box.widthAnchor.constraint(equalToConstant: VisualStyle.contentWidth),
                box.heightAnchor.constraint(equalToConstant: emptyHeight),
                empty.centerXAnchor.constraint(equalTo: box.centerXAnchor),
                empty.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            ])
            stack.addArrangedSubview(box)
        }
        for account in visible {
            stack.addArrangedSubview(AccountCardView(
                account: account,
                canWrite: canWrite && !isOffline,
                isRefreshing: isRefreshing,
                mutation: accountMutations[account.accountId],
                actionTarget: accountActionTarget,
                statusAction: statusAction,
                routingAction: routingAction,
                resetAction: resetAction,
                contextMenuProvider: contextMenuProvider
            ))
        }

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = contentHeight > maxHeight
        scrollView.autohidesScrollers = true
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        scrollView.documentView = document
        scrollView.alphaValue = isOffline ? 0.55 : 1
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: VisualStyle.inset + 2),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -VisualStyle.inset - 2),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            header.heightAnchor.constraint(equalToConstant: 20),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: VisualStyle.inset),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -VisualStyle.inset),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            stack.widthAnchor.constraint(equalToConstant: VisualStyle.contentWidth),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

/// Same header for every section so Usage and Accounts line up.
private func sectionHeader(_ title: String, meta: String?, accessory: NSView? = nil) -> NSStackView {
    let titleLabel = makeLabel(title, size: 13, weight: .semibold, color: VisualStyle.textPrimary)
    var views: [NSView] = [titleLabel]
    if let accessory {
        views.append(accessory)
    }
    views.append(NSView.spacer())
    if let meta {
        let metaLabel = makeLabel(meta, size: 11, color: VisualStyle.textMuted)
        metaLabel.alignment = .right
        views.append(metaLabel)
    }
    let header = NSStackView(views: views)
    header.orientation = .horizontal
    header.alignment = .centerY
    header.spacing = 6
    header.translatesAutoresizingMaskIntoConstraints = false
    return header
}

private final class UsageChartView: NSView {
    private let values: [Double]
    private let style: UsageChartStyle

    init(values: [Double], style: UsageChartStyle) {
        self.values = values
        self.style = style
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !values.isEmpty else {
            return
        }
        switch style {
        case .bars:
            drawBars()
        case .line, .area:
            drawLine(filled: style == .area)
        }
    }

    private func drawBars() {
        let peak = max(values.max() ?? 0, 1)
        let gap: CGFloat = values.count > 40 ? 1.5 : 3
        let barWidth = max(1.5, (bounds.width - gap * CGFloat(values.count - 1)) / CGFloat(values.count))
        let radius = min(2, barWidth / 2)
        for (index, value) in values.enumerated() {
            let x = CGFloat(index) * (barWidth + gap)
            if value <= 0 {
                VisualStyle.trackDim.setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: 0, width: barWidth, height: 2), xRadius: 1, yRadius: 1).fill()
                continue
            }
            let height = max(3, bounds.height * CGFloat(value / peak))
            // Latest interval is emphasized; everything else stays neutral.
            (index == values.count - 1 ? VisualStyle.blue : VisualStyle.chart).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: 0, width: barWidth, height: height), xRadius: radius, yRadius: radius).fill()
        }
    }

    /// Smoothed line (monotone-ish midpoint curves) with an optional soft fill and a dot on the latest point.
    private func drawLine(filled: Bool) {
        let peak = max(values.max() ?? 0, 1)
        let top = bounds.height - 3
        let step = values.count > 1 ? (bounds.width - 4) / CGFloat(values.count - 1) : 0
        let points = values.enumerated().map { index, value in
            NSPoint(x: 2 + CGFloat(index) * step, y: 1 + top * CGFloat(max(value, 0) / peak))
        }
        let line = NSBezierPath()
        line.move(to: points[0])
        for index in 1..<max(points.count, 1) where points.count > 1 {
            let previous = points[index - 1], current = points[index]
            let midX = (previous.x + current.x) / 2
            line.curve(to: current, controlPoint1: NSPoint(x: midX, y: previous.y), controlPoint2: NSPoint(x: midX, y: current.y))
        }

        VisualStyle.trackDim.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        if filled, let area = line.copy() as? NSBezierPath, let last = points.last {
            area.line(to: NSPoint(x: last.x, y: 0))
            area.line(to: NSPoint(x: points[0].x, y: 0))
            area.close()
            NSGradient(starting: VisualStyle.blue.withAlphaComponent(0.28), ending: VisualStyle.blue.withAlphaComponent(0.02))?
                .draw(in: area, angle: -90)
        }
        line.lineWidth = 1.5
        line.lineJoinStyle = .round
        line.lineCapStyle = .round
        (filled ? VisualStyle.blue : VisualStyle.chart.withAlphaComponent(0.9)).setStroke()
        line.stroke()
        if let last = points.last {
            VisualStyle.blue.setFill()
            NSBezierPath(ovalIn: NSRect(x: last.x - 2.5, y: last.y - 2.5, width: 5, height: 5)).fill()
        }
    }
}

private final class UsageSummaryView: RoundedPanelView {
    static let height: CGFloat = 150

    init(overview: DashboardOverview, period: UsagePeriod, chartStyle: UsageChartStyle) {
        super.init(width: VisualStyle.menuWidth, height: Self.height)
        let metrics = overview.summary?.metrics
        let header = sectionHeader("Usage", meta: period.title)
        addSubview(header)

        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.backgroundColor = VisualStyle.cardBackground.resolvedCG
        card.layer?.borderColor = VisualStyle.border.resolvedCG
        card.layer?.borderWidth = 1
        card.layer?.cornerRadius = VisualStyle.cardRadius
        addSubview(card)

        func metric(_ name: String, _ value: String) -> NSView {
            let valueLabel = makeLabel(value, size: 14, weight: .semibold, color: VisualStyle.textPrimary)
            valueLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
            let stack = NSStackView(views: [makeLabel(name, size: 11, color: VisualStyle.textMuted), valueLabel])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 1
            return stack
        }
        let cost = overview.summary?.cost?.totalUsd.map(formatUSD) ?? "--"
        let tokens = metrics?.tokens.map { formatCompactCount(Double($0)) } ?? "--"
        let requests = metrics?.requests.map { formatCompactCount(Double($0)) } ?? "--"
        let errors = metrics?.errorRate.map { String(format: "%.1f%%", $0 * 100) } ?? "--"
        let metricRow = NSStackView(views: [metric("Cost", cost), metric("Tokens", tokens), metric("Requests", requests), metric("Errors", errors)])
        metricRow.orientation = .horizontal
        metricRow.distribution = .fillEqually
        metricRow.alignment = .top
        metricRow.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(metricRow)

        let points = (overview.trends?.tokens ?? []).sorted { $0.t < $1.t }
        let chart = UsageChartView(values: points.map(\.v), style: chartStyle)
        chart.toolTip = "Tokens per interval, \(period.title.lowercased())"
        card.addSubview(chart)
        let peak = points.map(\.v).max().map { "Peak \(formatCompactCount($0))" } ?? ""
        let axis = NSStackView(views: [
            makeLabel(points.first.map { DateFormatters.shortDate.string(from: $0.t) } ?? "", size: 10, color: VisualStyle.textMuted),
            NSView.spacer(),
            makeLabel(points.isEmpty ? "No activity" : "\(peak) · Now", size: 10, color: VisualStyle.textMuted),
        ])
        axis.orientation = .horizontal
        axis.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(axis)

        let inset = VisualStyle.inset
        let pad = VisualStyle.cardPadding
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset + 2),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset - 2),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            header.heightAnchor.constraint(equalToConstant: 20),
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            card.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            metricRow.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: pad),
            metricRow.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -pad),
            metricRow.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            chart.leadingAnchor.constraint(equalTo: metricRow.leadingAnchor),
            chart.trailingAnchor.constraint(equalTo: metricRow.trailingAnchor),
            chart.topAnchor.constraint(equalTo: metricRow.bottomAnchor, constant: 12),
            chart.heightAnchor.constraint(equalToConstant: 34),
            axis.leadingAnchor.constraint(equalTo: metricRow.leadingAnchor),
            axis.trailingAnchor.constraint(equalTo: metricRow.trailingAnchor),
            axis.topAnchor.constraint(equalTo: chart.bottomAnchor, constant: 4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

/// Stacks fixed-height panels top to bottom inside the single menu view item.
private final class StackedPanelView: NSView {
    init(panels: [NSView]) {
        let height = panels.reduce(0) { $0 + $1.frame.height }
        super.init(frame: NSRect(x: 0, y: 0, width: VisualStyle.menuWidth, height: height))
        var top = height
        for panel in panels {
            top -= panel.frame.height
            panel.frame.origin = NSPoint(x: 0, y: top)
            panel.autoresizingMask = [.width]
            addSubview(panel)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

private final class VersionFooterView: NSView {
    init(text: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: VisualStyle.menuWidth, height: 16))
        let label = makeLabel(text, size: 10, color: VisualStyle.textMuted)
        label.alignment = .right
        addSubview(label)
        NSLayoutConstraint.activate([
            // Aligns with native menu item titles.
            // Right edge lines up with the menu's key-equivalent column (⌘Q).
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 0),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

private final class StatusMessageView: RoundedPanelView {
    init(title: String, message: String, detail: String? = nil) {
        super.init(width: VisualStyle.menuWidth, height: detail == nil ? 96 : 118)
        let titleLabel = makeLabel(title, size: 15, weight: .bold, color: VisualStyle.textPrimary)
        let messageLabel = makeLabel(message, size: 12, color: VisualStyle.textSecondary)
        messageLabel.maximumNumberOfLines = 2
        var views: [NSView] = [titleLabel, messageLabel]
        if let detail {
            let detailLabel = makeLabel(detail, size: 11, color: VisualStyle.textMuted)
            detailLabel.maximumNumberOfLines = 2
            views.append(detailLabel)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

private final class MenuContentContainerView: NSView {
    init(content: NSView) {
        super.init(frame: content.frame)
        replaceContent(with: content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func replaceContent(with content: NSView) {
        subviews.forEach { $0.removeFromSuperview() }
        frame.size = content.frame.size
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }
}

/// Scroll document that pins content to the top.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private extension NSView {
    static func spacer() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }
}

private func makeLabel(
    _ text: String,
    size: CGFloat,
    weight: NSFont.Weight = .regular,
    color: NSColor = VisualStyle.textPrimary
) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: size, weight: weight)
    label.textColor = color
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.backgroundColor = .clear
    return label
}

private func shieldView() -> NSView {
    let imageView = NSImageView()
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.image = NSImage(systemSymbolName: "checkmark.shield", accessibilityDescription: "authorized")
    imageView.toolTip = "Security work authorized"
    imageView.contentTintColor = VisualStyle.green
    imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
    NSLayoutConstraint.activate([
        imageView.widthAnchor.constraint(equalToConstant: 18),
        imageView.heightAnchor.constraint(equalToConstant: 18),
    ])
    return imageView
}

private func quotaColor(_ percent: Double) -> NSColor {
    switch quotaTone(for: percent) {
    case .green:
        return VisualStyle.green
    case .amber:
        return VisualStyle.amber
    case .red:
        return VisualStyle.red
    }
}

private func quotaTrackColor(_ percent: Double) -> NSColor {
    switch quotaTone(for: percent) {
    case .green:
        return VisualStyle.greenDim
    case .amber:
        return VisualStyle.amberDim
    case .red:
        return VisualStyle.redDim
    }
}

private func accountTitle(_ account: AccountSummary) -> String {
    if let alias = account.alias, !alias.isEmpty {
        return alias
    }
    return account.displayName
}

private func accountSubtitle(_ account: AccountSummary) -> String {
    if accountTitle(account).localizedCaseInsensitiveCompare(account.email) != .orderedSame {
        return "\(account.planType.capitalized) | \(account.email)"
    }
    let accountId = account.accountId.count > 12 ? String(account.accountId.prefix(12)) + "..." : account.accountId
    return "\(account.planType.capitalized) | \(accountId)"
}

private func accountSortKey(_ account: AccountSummary) -> AccountSortKey {
    AccountSortKey(
        id: account.accountId,
        name: accountTitle(account),
        status: account.status,
        primaryRemaining: account.usage?.primaryRemainingPercent,
        secondaryRemaining: account.usage?.secondaryRemainingPercent,
        primaryResetAt: account.resetAtPrimary,
        secondaryResetAt: account.resetAtSecondary
    )
}

/// Compact header control (icon + optional text) that highlights on hover like the reset action.
private final class HeaderChipButton: NSButton {
    private var hoverTrackingArea: NSTrackingArea?

    init(title: String?, symbolName: String, active: Bool, target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        setButtonType(.momentaryChange)
        self.target = target
        self.action = action
        wantsLayer = true
        layer?.cornerRadius = 9
        let color = active ? VisualStyle.blue : VisualStyle.textSecondary
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title ?? symbolName)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        contentTintColor = color
        if let title {
            imagePosition = .imageLeading
            imageHugsTitle = true
            attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: color,
            ])
        } else {
            imagePosition = .imageOnly
            self.title = ""
        }
        heightAnchor.constraint(equalToConstant: 18).isActive = true
    }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 10, height: 18)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = VisualStyle.labelWash.resolvedCG
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

private func accountSort(_ lhs: AccountSummary, _ rhs: AccountSummary) -> Bool {
    if lhs.status == "active", rhs.status != "active" {
        return true
    }
    if lhs.status != "active", rhs.status == "active" {
        return false
    }
    return accountTitle(lhs).localizedCaseInsensitiveCompare(accountTitle(rhs)) == .orderedAscending
}

private func quotaViewsForAccount(_ account: AccountSummary) -> [NSView] {
    var rows: [NSView] = []
    if account.windowMinutesPrimary != nil || account.usage?.primaryRemainingPercent != nil {
        rows.append(QuotaMiniView(label: "5h", remainingPercent: account.usage?.primaryRemainingPercent,
                                  resetAt: account.resetAtPrimary, windowMinutes: account.windowMinutesPrimary))
    }
    if account.windowMinutesSecondary != nil || account.usage?.secondaryRemainingPercent != nil {
        rows.append(QuotaMiniView(label: "Weekly", remainingPercent: account.usage?.secondaryRemainingPercent,
                                  resetAt: account.resetAtSecondary, windowMinutes: account.windowMinutesSecondary))
    }
    if account.windowMinutesMonthly != nil || account.usage?.monthlyRemainingPercent != nil {
        rows.append(QuotaMiniView(label: "Monthly", remainingPercent: account.usage?.monthlyRemainingPercent,
                                  resetAt: account.resetAtMonthly, windowMinutes: account.windowMinutesMonthly))
    }
    return rows
}

private func warmupStatus(_ account: AccountSummary) -> String {
    if account.limitWarmupEnabled == true {
        return "Warm-up on"
    }
    return "Warm-up off"
}

private func warmupAttempt(_ account: AccountSummary) -> String {
    guard let warmup = account.limitWarmup else {
        return "No attempts"
    }
    if let completedAt = warmup.completedAt {
        return "\(warmup.status.capitalized) \(elapsedTime(since: completedAt)) ago"
    }
    return "\(warmup.status.capitalized) \(elapsedTime(since: warmup.attemptedAt)) ago"
}

/// Aggregate quota across accounts that can serve traffic (see `isCountedForQuota`).
private struct QuotaSummary {
    let primary: Double?
    let secondary: Double?
    let monthly: Double?
    let activeCount: Int
    let countedCount: Int
    let attentionCount: Int

    init(accounts: [AccountSummary]) {
        let counted = accounts.filter { isCountedForQuota(status: $0.status) }
        primary = averageRemaining(counted.map { $0.usage?.primaryRemainingPercent })
        secondary = averageRemaining(counted.map { $0.usage?.secondaryRemainingPercent })
        monthly = averageRemaining(counted.map { $0.usage?.monthlyRemainingPercent })
        activeCount = accounts.filter { $0.status == "active" }.count
        countedCount = counted.count
        attentionCount = accounts.filter { accountNeedsReauthentication($0.status) }.count
    }
}

/// Posts macOS notifications for aggregate quota threshold crossings and accounts that newly need re-auth.
@MainActor
private final class StatusNotifier: NSObject, UNUserNotificationCenterDelegate {
    private let settings: SettingsStore
    private var tracker = QuotaAlertTracker()
    private var previousStatuses: [String: String] = [:]
    var onActivate: (() -> Void)?

    init(settings: SettingsStore) {
        self.settings = settings
    }

    /// UNUserNotificationCenter traps when the binary isn't running from an app bundle.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    var isEnabled: Bool {
        settings.notificationsEnabled && center != nil
    }

    func configure() {
        center?.delegate = self
        if settings.notificationsEnabled {
            Task {
                _ = await requestAuthorization()
            }
        }
    }

    /// Returns false when notifications are unavailable or denied in System Settings.
    func setEnabled(_ enabled: Bool) async -> Bool {
        settings.notificationsEnabled = enabled
        guard enabled else {
            return true
        }
        return await requestAuthorization()
    }

    /// Forget baselines (e.g. after switching servers) so the next refresh doesn't alert on stale diffs.
    func reset() {
        tracker.reset()
        previousStatuses = [:]
    }

    func process(_ accounts: [AccountSummary]) {
        // State is tracked even while disabled, so enabling later doesn't replay old crossings.
        let summary = QuotaSummary(accounts: accounts)
        let windows: [(key: String, label: String, value: Double?)] = [
            ("5h", "5-hour", summary.primary),
            ("weekly", "Weekly", summary.secondary),
            ("monthly", "Monthly", summary.monthly),
        ]
        var quotaAlerts: [(label: String, value: Double, threshold: Double)] = []
        for window in windows {
            if let threshold = tracker.update(key: window.key, percent: window.value), let value = window.value {
                quotaAlerts.append((window.label, value, threshold))
            }
        }

        let currentStatuses = Dictionary(accounts.map { ($0.accountId, $0.status) }, uniquingKeysWith: { _, last in last })
        let reauthIds = accountsNeedingNewReauthAlert(previous: previousStatuses, current: currentStatuses)
        previousStatuses = currentStatuses
        processCreditExpiries(accounts)

        guard isEnabled else {
            return
        }
        for alert in quotaAlerts {
            post(
                id: "quota-\(alert.label)",
                title: "\(alert.label) quota below \(Int(alert.threshold))%",
                body: "Average remaining is \(Int(round(alert.value)))% across \(summary.countedCount) usable account(s)."
            )
        }
        for accountId in reauthIds {
            guard let account = accounts.first(where: { $0.accountId == accountId }) else {
                continue
            }
            let label = accountStatusPresentation(account.status).label
            var body = "\(accountTitle(account)) is \(label.lowercased()). Click the account badge to sign in again."
            if let reason = account.deactivationReason, !reason.isEmpty {
                body += " Reason: \(reason)"
            }
            post(id: "reauth-\(accountId)", title: "Codex LB account needs attention", body: body)
        }
    }

    /// Warns once per credit batch when unused reset credits expire within 24 hours.
    private func processCreditExpiries(_ accounts: [AccountSummary]) {
        var alerted = settings.alertedCreditExpiries
        var changed = false
        for account in accounts {
            let count = account.availableResetCredits ?? 0
            guard let expiresAt = account.resetCreditNearestExpiresAt,
                  resetCreditExpiresSoon(count: count, expiresAt: expiresAt),
                  canRedeemResetCredit(status: account.status, availableCount: count) else {
                continue
            }
            let key = resetCreditExpiryAlertKey(accountId: account.accountId, expiresAt: expiresAt)
            guard !alerted.contains(key) else {
                continue
            }
            alerted.append(key)
            changed = true
            guard isEnabled else {
                continue
            }
            let credits = count == 1 ? "A reset credit" : "\(count) reset credits"
            post(
                id: "credit-\(key)",
                title: "Reset credit expires in \(compactRemaining(until: expiresAt))",
                body: "\(credits) on \(accountTitle(account)) will expire unused. Open the menu to use it."
            )
        }
        if changed {
            settings.alertedCreditExpiries = alerted
        }
    }

    func postServerUpdate(current: String, latest: String) {
        guard isEnabled else {
            return
        }
        post(
            id: "server-update-\(latest)",
            title: "codex-lb v\(latest) is available",
            body: "This server runs v\(current). Open the menu for the release notes."
        )
    }

    private func requestAuthorization() async -> Bool {
        guard let center else {
            return false
        }
        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    private func post(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // Stable identifiers replace an older undelivered alert of the same kind instead of stacking.
        center?.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            self.onActivate?()
        }
        completionHandler()
    }
}

private enum SettingsChange {
    case serverURL(String)
    case launchAtLogin
    case notifications(Bool)
    case display
    case menuContent(periodChanged: Bool)
    case checkForUpdates
    case checkServerVersion
    case appearance
    case hotKey
    case forgetSavedLogin
}

@MainActor
private final class SettingsWindowController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private let settings: SettingsStore
    private let onChange: (SettingsChange) -> Void
    private let window: NSWindow

    private let serverField = NSTextField()
    private let launchAtLogin = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private let notifications = NSButton(checkboxWithTitle: "Quota and account alerts", target: nil, action: nil)
    private let autoUpdate = NSButton(checkboxWithTitle: "Check for updates automatically", target: nil, action: nil)
    private let hotKeyToggle = NSButton(checkboxWithTitle: "Open menu with \(GlobalHotKey.displayString)", target: nil, action: nil)
    private let stylePopup = NSPopUpButton()
    private let colorPopup = NSPopUpButton()
    private let showPrimary = NSButton(checkboxWithTitle: "5h", target: nil, action: nil)
    private let showSecondary = NSButton(checkboxWithTitle: "Weekly", target: nil, action: nil)
    private let showCount = NSButton(checkboxWithTitle: "Accounts (active/total)", target: nil, action: nil)
    private let showUsage = NSButton(checkboxWithTitle: "Show usage summary", target: nil, action: nil)
    private let periodPopup = NSPopUpButton()
    private let chartPopup = NSPopUpButton()
    private let savedLoginLabel = NSTextField(labelWithString: "")
    private let forgetButton = NSButton(title: "Forget Saved Login", target: nil, action: nil)
    private let versionLabel = NSTextField(labelWithString: "")
    private let themePopup = NSPopUpButton()
    private let brightnessSlider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let serverVersionLabel = NSTextField(labelWithString: "Not checked yet")

    init(settings: SettingsStore, onChange: @escaping (SettingsChange) -> Void) {
        self.settings = settings
        self.onChange = onChange
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "Codex LB Status Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self
        buildLayout()
        reload()
    }

    func show(appVersion: String) {
        versionLabel.stringValue = "Codex LB Status v\(appVersion)"
        reload()
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// Syncs every control with the stored settings (also used after external changes).
    func reload() {
        serverField.stringValue = settings.baseURLString
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLogin.state = .on
            launchAtLogin.toolTip = nil
        case .requiresApproval:
            launchAtLogin.state = .mixed
            launchAtLogin.toolTip = "Approval required in System Settings > General > Login Items"
        default:
            launchAtLogin.state = .off
            launchAtLogin.toolTip = nil
        }
        notifications.state = settings.notificationsEnabled ? .on : .off
        autoUpdate.state = settings.autoCheckUpdates ? .on : .off
        hotKeyToggle.state = settings.globalHotKeyEnabled ? .on : .off
        stylePopup.selectItem(at: StatusBarStyle.allCases.firstIndex(of: settings.statusBarStyle) ?? 0)
        colorPopup.selectItem(at: StatusBarColorMode.allCases.firstIndex(of: settings.statusBarColorMode) ?? 0)
        let items = settings.statusBarItems
        showPrimary.state = items.primary ? .on : .off
        showSecondary.state = items.secondary ? .on : .off
        showCount.state = items.accountCount ? .on : .off
        showUsage.state = settings.showUsageSummary ? .on : .off
        periodPopup.selectItem(at: UsagePeriod.allCases.firstIndex(of: settings.usagePeriod) ?? 1)
        periodPopup.isEnabled = settings.showUsageSummary
        chartPopup.selectItem(at: UsageChartStyle.allCases.firstIndex(of: settings.usageChartStyle) ?? 0)
        chartPopup.isEnabled = settings.showUsageSummary
        let hasSaved = DashboardPasswordStore.hasAny(for: settings.baseURLString)
        savedLoginLabel.stringValue = hasSaved
            ? "A password for this server is saved in Keychain."
            : "No password saved for this server."
        forgetButton.isEnabled = hasSaved
        themePopup.selectItem(at: AppTheme.allCases.firstIndex(of: settings.theme) ?? 0)
        brightnessSlider.doubleValue = settings.brightness
    }

    func setServerStatus(_ text: String) {
        serverVersionLabel.stringValue = text
    }

    private func buildLayout() {
        serverField.placeholderString = "http://127.0.0.1:2455"
        serverField.delegate = self
        serverField.target = self
        serverField.action = #selector(serverURLCommitted)
        serverField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        let applyServer = NSButton(title: "Apply", target: self, action: #selector(serverURLCommitted))
        let serverRow = NSStackView(views: [serverField, applyServer])
        serverRow.spacing = 8

        for (button, selector) in [
            (launchAtLogin, #selector(launchAtLoginChanged)),
            (notifications, #selector(notificationsChanged)),
            (autoUpdate, #selector(autoUpdateChanged)),
            (hotKeyToggle, #selector(hotKeyChanged)),
            (showPrimary, #selector(displayChanged)),
            (showSecondary, #selector(displayChanged)),
            (showCount, #selector(displayChanged)),
            (showUsage, #selector(menuContentChanged)),
        ] {
            button.target = self
            button.action = selector
        }
        launchAtLogin.allowsMixedState = true

        stylePopup.addItems(withTitles: StatusBarStyle.allCases.map(\.title))
        stylePopup.target = self
        stylePopup.action = #selector(displayChanged)
        colorPopup.addItems(withTitles: StatusBarColorMode.allCases.map(\.menuTitle))
        colorPopup.target = self
        colorPopup.action = #selector(displayChanged)
        periodPopup.addItems(withTitles: UsagePeriod.allCases.map(\.title))
        periodPopup.target = self
        periodPopup.action = #selector(periodChanged)
        chartPopup.addItems(withTitles: UsageChartStyle.allCases.map(\.title))
        chartPopup.target = self
        chartPopup.action = #selector(chartStyleChanged)

        themePopup.addItems(withTitles: AppTheme.allCases.map(\.title))
        themePopup.target = self
        themePopup.action = #selector(appearanceChanged)
        brightnessSlider.target = self
        brightnessSlider.action = #selector(appearanceChanged)
        brightnessSlider.isContinuous = true
        brightnessSlider.numberOfTickMarks = 3
        brightnessSlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let dim = NSTextField(labelWithString: "Dim")
        let bright = NSTextField(labelWithString: "Bright")
        for label in [dim, bright] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
        }
        let resetBrightness = NSButton(title: "Reset", target: self, action: #selector(resetBrightness))
        resetBrightness.controlSize = .small
        let brightnessRow = NSStackView(views: [dim, brightnessSlider, bright, resetBrightness])
        brightnessRow.spacing = 6
        serverVersionLabel.textColor = .secondaryLabelColor
        let checkServer = NSButton(title: "Check", target: self, action: #selector(checkServerVersion))
        let serverVersionRow = NSStackView(views: [serverVersionLabel, checkServer])
        serverVersionRow.spacing = 10

        let showRow = NSStackView(views: [showPrimary, showSecondary, showCount])
        showRow.spacing = 14
        let checkNow = NSButton(title: "Check Now", target: self, action: #selector(checkNow))
        let updateRow = NSStackView(views: [autoUpdate, checkNow])
        updateRow.spacing = 12
        forgetButton.target = self
        forgetButton.action = #selector(forgetLogin)
        savedLoginLabel.textColor = .secondaryLabelColor
        versionLabel.textColor = .tertiaryLabelColor
        versionLabel.font = .systemFont(ofSize: 11)

        func caption(_ text: String) -> NSTextField {
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.preferredMaxLayoutWidth = 330
            return label
        }
        var headers: [NSTextField] = []
        func header(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            headers.append(label)
            return label
        }

        let rows: [[NSView]] = [
            [header("General"), NSGridCell.emptyContentView],
            [NSTextField(labelWithString: "Server URL:"), serverRow],
            [NSGridCell.emptyContentView, launchAtLogin],
            [NSTextField(labelWithString: "Shortcut:"), hotKeyToggle],
            [NSTextField(labelWithString: "Notifications:"), notifications],
            [NSTextField(labelWithString: "Updates:"), updateRow],
            [NSTextField(labelWithString: "codex-lb server:"), serverVersionRow],
            [header("Appearance"), NSGridCell.emptyContentView],
            [NSTextField(labelWithString: "Theme:"), themePopup],
            [NSTextField(labelWithString: "Brightness:"), brightnessRow],
            [header("Status Bar"), NSGridCell.emptyContentView],
            [NSTextField(labelWithString: "Style:"), stylePopup],
            [NSTextField(labelWithString: "Colors:"), colorPopup],
            [NSGridCell.emptyContentView, caption("Warnings Only colors just the ! and quota below 30%.")],
            [NSTextField(labelWithString: "Show:"), showRow],
            [header("Menu"), NSGridCell.emptyContentView],
            [NSGridCell.emptyContentView, showUsage],
            [NSTextField(labelWithString: "Usage period:"), periodPopup],
            [NSTextField(labelWithString: "Chart:"), chartPopup],
            [header("Login"), NSGridCell.emptyContentView],
            [NSGridCell.emptyContentView, savedLoginLabel],
            [NSGridCell.emptyContentView, forgetButton],
        ]
        let grid = NSGridView(views: rows)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 9
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        for (index, row) in rows.enumerated() where headers.contains(where: { $0 === row[0] }) {
            let gridRow = grid.row(at: index)
            gridRow.mergeCells(in: NSRange(location: 0, length: 2))
            gridRow.cell(at: 0).xPlacement = .leading
            if index > 0 {
                gridRow.topPadding = 10
            }
        }

        let content = NSView()
        content.addSubview(grid)
        content.addSubview(versionLabel)
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            versionLabel.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 16),
            versionLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            versionLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        window.contentView = content
    }

    @objc private func serverURLCommitted() {
        onChange(.serverURL(serverField.stringValue))
        reload()
    }

    @objc private func launchAtLoginChanged() {
        onChange(.launchAtLogin)
    }

    @objc private func notificationsChanged() {
        onChange(.notifications(notifications.state == .on))
    }

    @objc private func autoUpdateChanged() {
        settings.autoCheckUpdates = autoUpdate.state == .on
    }

    @objc private func hotKeyChanged() {
        settings.globalHotKeyEnabled = hotKeyToggle.state == .on
        onChange(.hotKey)
    }

    @objc private func checkNow() {
        onChange(.checkForUpdates)
    }

    @objc private func displayChanged() {
        settings.statusBarStyle = StatusBarStyle.allCases[max(0, stylePopup.indexOfSelectedItem)]
        settings.statusBarColorMode = StatusBarColorMode.allCases[max(0, colorPopup.indexOfSelectedItem)]
        settings.statusBarItems = StatusBarItems(
            primary: showPrimary.state == .on,
            secondary: showSecondary.state == .on,
            accountCount: showCount.state == .on
        )
        onChange(.display)
    }

    @objc private func menuContentChanged() {
        settings.showUsageSummary = showUsage.state == .on
        periodPopup.isEnabled = settings.showUsageSummary
        chartPopup.isEnabled = settings.showUsageSummary
        onChange(.menuContent(periodChanged: false))
    }

    @objc private func chartStyleChanged() {
        settings.usageChartStyle = UsageChartStyle.allCases[max(0, chartPopup.indexOfSelectedItem)]
        onChange(.menuContent(periodChanged: false))
    }

    @objc private func periodChanged() {
        let period = UsagePeriod.allCases[max(0, periodPopup.indexOfSelectedItem)]
        guard period != settings.usagePeriod else { return }
        settings.usagePeriod = period
        onChange(.menuContent(periodChanged: true))
    }

    @objc private func forgetLogin() {
        onChange(.forgetSavedLogin)
    }

    @objc private func appearanceChanged() {
        settings.theme = AppTheme.allCases[max(0, themePopup.indexOfSelectedItem)]
        settings.brightness = brightnessSlider.doubleValue
        onChange(.appearance)
    }

    @objc private func resetBrightness() {
        brightnessSlider.doubleValue = 0.5
        appearanceChanged()
    }

    @objc private func checkServerVersion() {
        serverVersionLabel.stringValue = "Checking..."
        onChange(.checkServerVersion)
    }
}

@MainActor
private final class ReauthFlow {
    let accountId: String
    let accountName: String
    let flowId: String?
    let method: String
    let authorizationURL: URL?
    let verificationURL: URL?
    let userCode: String?
    let deviceAuthId: String?
    let intervalSeconds: Int
    let expiresAt: Date
    var pollTask: Task<Void, Never>?

    init(accountId: String, accountName: String, response: OAuthStartResponse) {
        self.accountId = accountId
        self.accountName = accountName
        flowId = response.flowId
        method = response.method == "device" ? "device" : "browser"
        authorizationURL = response.authorizationUrl.flatMap(URL.init(string:))
        verificationURL = response.verificationUrl.flatMap(URL.init(string:))
        userCode = response.userCode
        deviceAuthId = response.deviceAuthId
        intervalSeconds = max(1, response.intervalSeconds ?? 2)
        // Browser flows expire server-side after 15 minutes.
        expiresAt = Date().addingTimeInterval(TimeInterval(response.expiresInSeconds ?? 15 * 60))
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = SettingsStore()
    private lazy var client = CodexLBClient(settings: settings)
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var overview: DashboardOverview?
    private var authSession: AuthSession?
    private var latestError: String?
    private var isRefreshing = false
    private var isMenuOpen = false
    private var lastRefreshedAt: Date?
    private var refreshTimer: Timer?
    private var accountMutations: [String: AccountMutation] = [:]
    private var reauthFlows: [String: ReauthFlow] = [:]
    /// Set while a re-auth instruction alert is modal, so a finished flow can dismiss it.
    private var activeReauthPromptAccountId: String?
    private lazy var notifier = StatusNotifier(settings: settings)
    /// Saved-credential login is tried once per server until it succeeds, so a stale password
    /// doesn't hit the server's login rate limiter on every refresh.
    private var autoLoginAttemptedForURL: String?
    private var savedLoginError: String?
    private let updater = AppUpdater()
    private var appearanceObservation: NSKeyValueObservation?
    private var availableUpdate: AppUpdater.Update?
    private var updateCheckTimer: Timer?
    private var isInstallingUpdate = false
    private var serverRuntime: RuntimeVersion?
    private var serverUpdateVersion: String?
    private var serverReleaseURL: URL?
    /// Set when a refresh fails while older data is still shown.
    private var offlineSince: Date?
    private var hotKey: GlobalHotKey?
    private var rightClickMonitor: Any?
    private var lastServerVersionCheck: Date?
    private var settingsWindow: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setStatusTitle("...")
        notifier.onActivate = { [weak self] in
            self?.statusItem.button?.performClick(nil)
        }
        notifier.configure()
        installEditMenu()
        applyAppearance()
        updateGlobalHotKey()
        // Layer colors are resolved once per build, so rebuild when System theme flips light/dark.
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in
                self?.rebuildMenu(updateVisiblePanel: self?.isMenuOpen ?? false)
            }
        }
        rebuildMenu()
        // First check shortly after launch, then daily.
        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 24 * 3_600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkForUpdates(userInitiated: false)
            }
        }
        Task {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            await checkForUpdates(userInitiated: false)
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
        Task {
            await refresh()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        updateCheckTimer?.invalidate()
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        // Right-clicking an account card opens its actions. Menu tracking swallows rightMouseDown,
        // so find the card under the pointer from a local event monitor instead.
        guard rightClickMonitor == nil else { return }
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
            guard event.type == .rightMouseDown || event.modifierFlags.contains(.control),
                  let content = event.window?.contentView,
                  var view = content.hitTest(content.convert(event.locationInWindow, from: nil)) else {
                return event
            }
            while !(view is AccountCardView) {
                guard let parent = view.superview else { return event }
                view = parent
            }
            (view as? AccountCardView)?.openContextMenu()
            return nil
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        if let rightClickMonitor {
            NSEvent.removeMonitor(rightClickMonitor)
            self.rightClickMonitor = nil
        }
    }

    private func refresh(menuWasOpen: Bool? = nil) async {
        guard !isRefreshing else {
            return
        }
        let wasMenuOpen = menuWasOpen ?? isMenuOpen
        isRefreshing = true
        // Keep the last known quota visible during a refresh instead of flashing "...".
        if overview == nil {
            setStatusTitle("...")
        }
        rebuildMenu(updateVisiblePanel: wasMenuOpen)
        defer {
            isRefreshing = false
            rebuildMenu(updateVisiblePanel: isMenuOpen)
        }

        do {
            do {
                authSession = try await client.getSession()
            } catch ClientError.unauthorized {
                authSession = nil
            }
            if authSession?.authenticated == true {
                autoLoginAttemptedForURL = nil
            } else if autoLoginAttemptedForURL != settings.baseURLString {
                await restoreSavedLogin()
            }
            let fetched = try await client.fetchOverview()
            overview = fetched
            lastRefreshedAt = Date()
            latestError = nil
            offlineSince = nil
            updateStatusTitle()
            notifier.process(fetched.accounts)
            await checkServerVersionIfDue()
        } catch ClientError.unauthorized {
            overview = nil
            latestError = "Dashboard login required"
            setStatusTitle("Login")
            if let savedLoginError {
                latestError = "Dashboard login required (saved login failed: \(savedLoginError))"
                self.savedLoginError = nil
            }
        } catch {
            latestError = error.localizedDescription
            if overview != nil {
                // Keep the last good data on screen, dimmed, instead of replacing everything with "Error".
                offlineSince = offlineSince ?? Date()
                updateStatusTitle()
            } else {
                setStatusTitle("Error")
            }
        }
    }

    /// Signs in with the last role used for this server (Keychain password, or passwordless guest).
    /// Failures are swallowed: the overview fetch that follows reports "Dashboard login required".
    private func restoreSavedLogin() async {
        let baseURL = settings.baseURLString
        do {
            switch settings.loginRole(for: baseURL) {
            case .admin:
                guard let password = DashboardPasswordStore.read(.admin, for: baseURL) else {
                    return
                }
                autoLoginAttemptedForURL = baseURL
                let session = try await client.loginPassword(password)
                if session.totpRequiredOnLogin {
                    guard let code = promptText(
                        title: "TOTP required",
                        message: "Enter the dashboard TOTP code to restore the saved admin login.",
                        defaultValue: "",
                        secure: false
                    ), !code.isEmpty else {
                        return
                    }
                    authSession = try await client.verifyTotp(code)
                } else {
                    authSession = session
                }
            case .guest:
                let password = DashboardPasswordStore.read(.guest, for: baseURL)
                // Only attempt passwordless guest when the server said it doesn't need a password.
                guard password != nil || authSession?.guestAccessEnabled == true && authSession?.guestPasswordRequired == false else {
                    return
                }
                autoLoginAttemptedForURL = baseURL
                authSession = try await client.loginGuest(password: password)
            }
            if authSession?.authenticated == true {
                autoLoginAttemptedForURL = nil
            }
        } catch {
            savedLoginError = error.localizedDescription
        }
    }

    private func setStatusTitle(_ text: String) {
        statusItem.button?.appearsDisabled = false
        statusItem.button?.image = nil
        statusItem.button?.imagePosition = .noImage
        statusItem.button?.attributedTitle = NSAttributedString(string: text, attributes: [.font: NSFont.menuBarFont(ofSize: 0)])
        statusItem.button?.toolTip = nil
    }

    private func updateStatusTitle() {
        guard let overview else {
            setStatusTitle(latestError == nil ? "Status" : "Error")
            return
        }

        let summary = QuotaSummary(accounts: overview.accounts)
        let style = settings.statusBarStyle
        let items = settings.statusBarItems
        let colorMode = settings.statusBarColorMode
        let segments = statusTitleSegments(
            primary: summary.primary,
            secondary: summary.secondary,
            monthly: summary.monthly,
            activeCount: summary.activeCount,
            totalCount: overview.accounts.count,
            attentionCount: summary.attentionCount,
            items: items,
            style: style
        )
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        let title = NSMutableAttributedString()
        for (index, segment) in segments.enumerated() {
            if index > 0 {
                title.append(NSAttributedString(string: " ", attributes: [.font: font]))
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: font]
            if segment.kind == .attention {
                attributes[.font] = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .heavy)
            }
            // nil keeps the default menu bar text color (adapts to light/dark and highlight).
            if let tone = statusSegmentTone(segment.kind, mode: colorMode) {
                attributes[.foregroundColor] = menuBarColor(tone)
            }
            title.append(NSAttributedString(string: segment.text, attributes: attributes))
        }

        var meterValues: [Double?] = []
        if style != .text {
            if items.primary, summary.primary != nil { meterValues.append(summary.primary) }
            if items.secondary, summary.secondary != nil { meterValues.append(summary.secondary) }
            if meterValues.isEmpty, items.primary || items.secondary, let monthly = summary.monthly {
                meterValues.append(monthly)
            }
            if meterValues.isEmpty {
                // Keep the item visible and clickable even when every window is hidden or unknown.
                meterValues.append(summary.primary ?? summary.secondary ?? summary.monthly)
            }
        }
        let button = statusItem.button
        if meterValues.isEmpty {
            button?.image = nil
            button?.imagePosition = .noImage
        } else {
            button?.image = quotaMeterImage(meterValues, colorMode: colorMode)
            button?.imagePosition = title.length == 0 ? .imageOnly : .imageLeading
            if title.length > 0 {
                title.insert(NSAttributedString(string: " ", attributes: [.font: font]), at: 0)
            }
        }
        if offlineSince != nil {
            title.addAttribute(.foregroundColor, value: NSColor.labelColor.withAlphaComponent(0.4),
                               range: NSRange(location: 0, length: title.length))
        }
        button?.attributedTitle = title
        button?.appearsDisabled = offlineSince != nil

        var tooltip = [
            "5h \(summary.primary.map(formatPercent) ?? "--") · Weekly \(summary.secondary.map(formatPercent) ?? "--")",
            "Average remaining across \(summary.countedCount) usable account(s); paused and re-auth accounts are excluded.",
        ]
        if summary.attentionCount > 0 {
            tooltip.append("\(summary.attentionCount) account(s) need re-authentication.")
        }
        if offlineSince != nil {
            tooltip.insert("\(staleDataLabel(lastSuccess: lastRefreshedAt)): \(latestError ?? "server unreachable")", at: 0)
        }
        button?.toolTip = tooltip.joined(separator: "\n")
    }

    /// Stacked horizontal bars (one per window). Monochrome renders as a template image so macOS tints it.
    private func quotaMeterImage(_ values: [Double?], colorMode: StatusBarColorMode) -> NSImage {
        let width: CGFloat = 22
        let height: CGFloat = 16
        let barHeight: CGFloat = values.count == 1 ? 6 : 5
        let gap: CGFloat = 3
        let tones = values.map { $0.map { statusSegmentTone(.quota(quotaTone(for: $0)), mode: colorMode) } ?? nil }
        let isTemplate = tones.allSatisfy { $0 == nil }
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { [weak self] _ in
            let total = CGFloat(values.count) * barHeight + CGFloat(values.count - 1) * gap
            var y = (height + total) / 2 - barHeight
            for (index, value) in values.enumerated() {
                let track = NSRect(x: 0.5, y: y, width: width - 1, height: barHeight)
                (isTemplate ? NSColor.black.withAlphaComponent(0.3) : NSColor.labelColor.withAlphaComponent(0.25)).setFill()
                NSBezierPath(roundedRect: track, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
                if let value {
                    let fraction = CGFloat(min(max(value, 0), 100) / 100)
                    var fill = track
                    fill.size.width = max(fraction > 0 ? barHeight : 0, track.width * fraction)
                    let color = tones[index].flatMap { self?.menuBarColor($0) } ?? (isTemplate ? .black : .labelColor)
                    color.setFill()
                    NSBezierPath(roundedRect: fill, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
                }
                y -= barHeight + gap
            }
            return true
        }
        image.isTemplate = isTemplate
        image.accessibilityDescription = "Quota meter"
        return image
    }

    private func menuBarColor(_ tone: QuotaTone) -> NSColor {
        switch tone {
        case .green:
            return .systemGreen
        case .amber:
            return .systemOrange
        case .red:
            return .systemRed
        }
    }

    private func rebuildMenu(updateVisiblePanel: Bool = false) {
        let previousMenu = statusItem.menu
        let menu = NSMenu()
        menu.delegate = self
        // Status-item menus follow the menu bar, not NSApp.appearance, so pin the chosen theme here.
        menu.appearance = NSApp.appearance

        if let overview {
            if !overview.accounts.isEmpty {
                let accountsPanel = AccountsPanelView(
                    accounts: overview.accounts,
                    isRefreshing: isRefreshing,
                    lastRefreshedAt: lastRefreshedAt,
                    refreshTarget: self,
                    refreshAction: #selector(refreshNow),
                    canWrite: authSession?.role == "admin",
                    accountMutations: accountMutations,
                    accountActionTarget: self,
                    statusAction: #selector(toggleAccountStatus(_:)),
                    routingAction: #selector(changeRoutingPolicy(_:)),
                    resetAction: #selector(resetCreditTapped(_:)),
                    sort: settings.accountSort,
                    filter: settings.accountFilter,
                    sortAction: #selector(cycleAccountSort),
                    filterAction: #selector(toggleAccountFilter),
                    offlineSince: offlineSince,
                    contextMenuProvider: { [weak self] accountId in
                        self?.showAccountMenu(accountId)
                        return nil
                    }
                )
                let panels: [NSView] = settings.showUsageSummary
                    ? [accountsPanel, UsageSummaryView(overview: overview, period: settings.usagePeriod, chartStyle: settings.usageChartStyle)]
                    : [accountsPanel]
                menu.addItem(viewItem(StackedPanelView(panels: panels)))
            } else {
                menu.addItem(viewItem(StatusMessageView(
                    title: appDisplayName,
                    message: "No accounts imported yet.",
                    detail: "Server: \(settings.baseURLString)"
                )))
            }
        } else if let latestError {
            menu.addItem(viewItem(StatusMessageView(
                title: latestError.hasPrefix("Dashboard login required") ? "Login required" : "Codex LB Connection Error",
                message: latestError,
                detail: "Server: \(settings.baseURLString)"
            )))
        } else {
            menu.addItem(viewItem(StatusMessageView(
                title: appDisplayName,
                message: isRefreshing ? "Refreshing usage data..." : "No data loaded yet.",
                detail: "Server: \(settings.baseURLString)"
            )))
        }

        menu.addItem(.separator())
        if let availableUpdate {
            let item = actionItem("Update to v\(availableUpdate.version)...", #selector(installAvailableUpdate))
            item.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
            menu.addItem(item)
        }
        // macOS adds a gear to "Settings..." on its own; give every row an icon so titles share one column.
        func withIcon(_ item: NSMenuItem, _ symbol: String) -> NSMenuItem {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            return item
        }
        menu.addItem(withIcon(actionItem("Open Dashboard", #selector(openDashboard)), "safari"))
        if let sessionLabel = sessionMenuLabel(authenticated: authSession?.authenticated == true, role: authSession?.role) {
            // Signed in: one item; switching roles and signing out live in its submenu.
            let session = NSMenuItem(title: sessionLabel, action: nil, keyEquivalent: "")
            session.image = NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: nil)
            let submenu = NSMenu()
            if authSession?.role == "admin" {
                submenu.addItem(actionItem("Switch to Guest...", #selector(loginGuest)))
            } else {
                submenu.addItem(actionItem("Log In as Admin...", #selector(loginAdmin)))
            }
            // Passwordless dashboards (auth disabled) have no session to end.
            if authSession?.passwordRequired == true || authSession?.guestAccessEnabled == true {
                submenu.addItem(.separator())
                submenu.addItem(actionItem("Sign Out", #selector(signOut)))
            }
            session.submenu = submenu
            menu.addItem(session)
        } else {
            menu.addItem(withIcon(actionItem("Admin Login...", #selector(loginAdmin)), "person.badge.key"))
            menu.addItem(withIcon(actionItem("Guest Login...", #selector(loginGuest)), "person"))
        }
        menu.addItem(.separator())
        let settingsItem = actionItem("Settings...", #selector(openSettings))
        settingsItem.keyEquivalent = ","
        menu.addItem(withIcon(settingsItem, "gearshape"))
        menu.addItem(withIcon(actionItem("Check for Updates...", #selector(checkForUpdatesManually)), "arrow.triangle.2.circlepath"))
        if let latest = serverUpdateVersion {
            // Only takes a row when there is something to act on.
            let item = actionItem("codex-lb v\(latest) Available...", #selector(openServerRelease))
            item.image = NSImage(systemSymbolName: "arrow.up.circle", accessibilityDescription: nil)
            item.toolTip = "Open the codex-lb release notes"
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let quitItem = actionItem("Quit", #selector(quit))
        quitItem.keyEquivalent = "q"
        menu.addItem(withIcon(quitItem, "power"))
        menu.addItem(versionFooterItem())
        if updateVisiblePanel,
           let visibleItem = previousMenu?.items.first,
           let container = visibleItem.view as? MenuContentContainerView,
           let updatedView = menu.items.first?.view as? MenuContentContainerView,
           let updatedContent = updatedView.subviews.first {
            container.replaceContent(with: updatedContent)
            if let footer = previousMenu?.items.first(where: { $0.identifier == serverVersionMenuItemIdentifier }) {
                footer.view = VersionFooterView(text: versionFooterText())
            }
            previousMenu?.update()
        } else {
            statusItem.menu = menu
        }
    }

    private func viewItem(_ view: NSView) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = MenuContentContainerView(content: view)
        return item
    }

    @objc private func refreshNow() {
        let menuWasOpen = isMenuOpen
        Task {
            await refresh(menuWasOpen: menuWasOpen)
        }
    }

    @objc private func toggleAccountStatus(_ sender: BadgeView) {
        guard authSession?.role == "admin",
              let accountId = sender.accountId,
              let status = sender.currentValue else {
            return
        }
        if reauthFlows[accountId] != nil || accountNeedsReauthentication(status) {
            afterMenuCloses { [weak self] in
                self?.presentRecoveryOptions(accountId: accountId)
            }
            return
        }
        switch status {
        case "active":
            performAccountMutation(accountId: accountId, mutation: .pause)
        case "paused":
            performAccountMutation(accountId: accountId, mutation: .reactivate)
        default:
            return
        }
    }

    @objc private func changeRoutingPolicy(_ sender: BadgeView) {
        guard authSession?.role == "admin",
              let accountId = sender.accountId,
              let currentPolicy = sender.currentValue else {
            return
        }
        performAccountMutation(
            accountId: accountId,
            mutation: .routingPolicy(nextRoutingPolicy(after: currentPolicy))
        )
    }

    private func performAccountMutation(accountId: String, mutation: AccountMutation) {
        guard authSession?.role == "admin", accountMutations[accountId] == nil else {
            return
        }
        accountMutations[accountId] = mutation
        let menuWasOpen = isMenuOpen
        rebuildMenu(updateVisiblePanel: menuWasOpen)

        Task {
            do {
                switch mutation {
                case .pause:
                    try await client.pauseAccount(accountId)
                case .reactivate:
                    try await client.reactivateAccount(accountId)
                case .routingPolicy(let routingPolicy):
                    try await client.updateRoutingPolicy(accountId: accountId, routingPolicy: routingPolicy)
                case .alias(let alias):
                    try await client.setAlias(accountId: accountId, alias: alias)
                case .limitWarmup(let enabled):
                    try await client.setLimitWarmup(accountId: accountId, enabled: enabled)
                case .resetCredit, .reauth:
                    // Handled by their dedicated flows (confirmation / OAuth polling).
                    break
                }
                await refreshWhenIdle(menuWasOpen: menuWasOpen)
            } catch {
                accountMutations.removeValue(forKey: accountId)
                rebuildMenu(updateVisiblePanel: isMenuOpen)
                showError(error.localizedDescription)
                return
            }
            accountMutations.removeValue(forKey: accountId)
            rebuildMenu(updateVisiblePanel: isMenuOpen)
        }
    }

    private func refreshWhenIdle(menuWasOpen: Bool) async {
        while isRefreshing {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        await refresh(menuWasOpen: menuWasOpen)
    }

    // MARK: - Reset credits

    @objc private func resetCreditTapped(_ sender: ResetCreditButton) {
        let accountId = sender.accountId
        guard authSession?.role == "admin", accountMutations[accountId] == nil else {
            return
        }
        afterMenuCloses { [weak self] in
            self?.confirmAndRedeemResetCredit(accountId: accountId)
        }
    }

    private func confirmAndRedeemResetCredit(accountId: String) {
        guard let account = account(withId: accountId) else {
            return
        }
        Task {
            // Fresh snapshot: the confirmation must show the credit that will actually be consumed.
            let snapshot: ResetCreditsSnapshot?
            do {
                snapshot = try await client.getResetCredits(accountId)
            } catch {
                showError("Could not load reset credits: \(error.localizedDescription)")
                return
            }
            guard let snapshot, snapshot.availableCount > 0 else {
                showError(snapshot == nil
                    ? "Reset credit details are not loaded on the server yet. Try again after the next refresh."
                    : "No reset credits are available for \(accountTitle(account)).")
                await refresh()
                return
            }
            let expiries = snapshot.credits
                .filter { $0.status == "available" }
                .map { $0.expiresAt ?? .distantFuture }
                .sorted()
            let soonest = expiries.first.flatMap { $0 == .distantFuture ? nil : $0 }
            let others = expiries.dropFirst().filter { $0 != .distantFuture }
            let message = resetCreditConfirmationText(
                accountName: accountTitle(account),
                availableCount: snapshot.availableCount,
                soonestExpiresAt: soonest,
                otherExpiries: Array(others),
                formatDate: { DateFormatters.dateTime.string(from: $0) }
            )
            guard confirmDestructive(
                title: "Use a reset credit?",
                message: message,
                confirmTitle: "Use Reset Credit"
            ) else {
                return
            }
            await redeemResetCredit(account: account, redeemRequestId: UUID().uuidString)
        }
    }

    private func redeemResetCredit(account: AccountSummary, redeemRequestId: String) async {
        let accountId = account.accountId
        guard accountMutations[accountId] == nil else {
            return
        }
        accountMutations[accountId] = .resetCredit
        rebuildMenu(updateVisiblePanel: isMenuOpen)
        do {
            let result = try await client.consumeResetCredit(accountId, redeemRequestId: redeemRequestId)
            accountMutations.removeValue(forKey: accountId)
            await refreshWhenIdle(menuWasOpen: isMenuOpen)
            showInfo(title: "Reset credit used", message: "\(accountTitle(account)): \(resetCreditResultText(windowsReset: result.windowsReset))")
        } catch {
            accountMutations.removeValue(forKey: accountId)
            rebuildMenu(updateVisiblePanel: isMenuOpen)
            // Retrying with the same redeemRequestId is idempotent on the server, so a lost
            // response cannot burn a second credit.
            if confirmRetry(title: "Reset credit failed", message: error.localizedDescription) {
                await redeemResetCredit(account: account, redeemRequestId: redeemRequestId)
            } else {
                await refreshWhenIdle(menuWasOpen: isMenuOpen)
            }
        }
    }

    // MARK: - Re-authentication

    private func presentRecoveryOptions(accountId: String) {
        if let flow = reauthFlows[accountId] {
            presentReauthInstructions(flow)
            return
        }
        guard authSession?.role == "admin",
              accountMutations[accountId] == nil,
              let account = account(withId: accountId) else {
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Re-authenticate \(accountTitle(account))"
        var info = "Sign in again with the ChatGPT account \(account.email)."
        if let reason = account.deactivationReason, !reason.isEmpty {
            info += "\n\nReason: \(reason)"
        }
        info += "\n\nBrowser sign-in needs the Codex LB server to receive the localhost:1455 callback (or you paste the final URL). Device code works from any browser or device."
        alert.informativeText = info
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Browser Sign-in")
        alert.addButton(withTitle: "Device Code")
        let offersReactivate = account.status == "deactivated"
        if offersReactivate {
            // The server's reactivate endpoint accepts deactivated (but not reauth_required) accounts.
            alert.addButton(withTitle: "Reactivate Only")
        }
        alert.addButton(withTitle: "Cancel")
        alert.buttons.last?.keyEquivalent = "\u{1b}"

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            startReauth(account: account, method: "browser")
        case .alertSecondButtonReturn:
            startReauth(account: account, method: "device")
        case .alertThirdButtonReturn where offersReactivate:
            performAccountMutation(accountId: accountId, mutation: .reactivate)
        default:
            return
        }
    }

    private func startReauth(account: AccountSummary, method: String) {
        let accountId = account.accountId
        guard accountMutations[accountId] == nil else {
            return
        }
        accountMutations[accountId] = .reauth
        rebuildMenu(updateVisiblePanel: isMenuOpen)

        Task {
            let response: OAuthStartResponse
            do {
                response = try await client.startOAuth(method: method, accountId: accountId)
            } catch {
                accountMutations.removeValue(forKey: accountId)
                rebuildMenu(updateVisiblePanel: isMenuOpen)
                showError("Could not start sign-in: \(error.localizedDescription)")
                return
            }
            let flow = ReauthFlow(accountId: accountId, accountName: accountTitle(account), response: response)
            // The server falls back to device flow if it cannot bind the browser callback port.
            if flow.method == "browser", flow.authorizationURL == nil {
                accountMutations.removeValue(forKey: accountId)
                rebuildMenu(updateVisiblePanel: isMenuOpen)
                showError("The server did not return a sign-in URL.")
                return
            }
            reauthFlows[accountId] = flow
            flow.pollTask = Task { [weak self] in
                await self?.pollReauth(flow)
            }
            if flow.method == "device" {
                if let userCode = flow.userCode {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(userCode, forType: .string)
                }
                // Mirrors the dashboard: acknowledge the device flow right after start.
                if flow.deviceAuthId != nil, flow.userCode != nil {
                    _ = try? await client.completeOAuth(flowId: flow.flowId, deviceAuthId: flow.deviceAuthId, userCode: flow.userCode)
                }
                if let url = flow.verificationURL {
                    NSWorkspace.shared.open(url)
                }
            } else if let url = flow.authorizationURL {
                NSWorkspace.shared.open(url)
            }
            presentReauthInstructions(flow)
        }
    }

    private func presentReauthInstructions(_ flow: ReauthFlow) {
        guard reauthFlows[flow.accountId] === flow, activeReauthPromptAccountId == nil else {
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        let remaining = compactRemaining(until: flow.expiresAt)
        var field: NSTextField?

        if flow.method == "device" {
            let code = flow.userCode ?? "--"
            alert.messageText = "Enter code \(code)"
            alert.informativeText = """
            Open \(flow.verificationURL?.absoluteString ?? "the verification page") and sign in as \(flow.accountName), then enter the code above (already copied to the clipboard).

            This app detects completion automatically. Expires in \(remaining).
            """
            alert.addButton(withTitle: "Continue in Background")
            alert.addButton(withTitle: "Open Page Again")
            alert.addButton(withTitle: "Copy Code")
            alert.addButton(withTitle: "Cancel Sign-in")
        } else {
            alert.messageText = "Finish signing in to \(flow.accountName)"
            alert.informativeText = """
            Complete the ChatGPT sign-in in your browser. This app detects completion automatically.

            If the browser ends on a page that fails to load (localhost:1455, e.g. the server runs on another machine), copy that page's full URL and paste it below. Expires in \(remaining).
            """
            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
            input.placeholderString = "http://localhost:1455/auth/callback?code=..."
            alert.accessoryView = input
            field = input
            alert.addButton(withTitle: "Submit URL")
            alert.addButton(withTitle: "Continue in Background")
            alert.addButton(withTitle: "Open Page Again")
            alert.addButton(withTitle: "Cancel Sign-in")
        }
        if let field {
            alert.layout()
            alert.window.initialFirstResponder = field
        }

        activeReauthPromptAccountId = flow.accountId
        let response = alert.runModal()
        activeReauthPromptAccountId = nil
        // .abort: the flow finished while the alert was open.
        guard response != .abort, reauthFlows[flow.accountId] === flow else {
            return
        }

        let isDevice = flow.method == "device"
        switch (isDevice, response) {
        case (true, .alertFirstButtonReturn), (false, .alertSecondButtonReturn):
            return
        case (true, .alertSecondButtonReturn), (false, .alertThirdButtonReturn):
            if let url = isDevice ? flow.verificationURL : flow.authorizationURL {
                NSWorkspace.shared.open(url)
            }
            presentReauthInstructions(flow)
        case (true, .alertThirdButtonReturn):
            if let code = flow.userCode {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
            }
            presentReauthInstructions(flow)
        case (false, .alertFirstButtonReturn):
            let callbackURL = field?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !callbackURL.isEmpty else {
                presentReauthInstructions(flow)
                return
            }
            submitManualCallback(callbackURL, flow: flow)
        default:
            cancelReauth(flow)
        }
    }

    private func submitManualCallback(_ callbackURL: String, flow: ReauthFlow) {
        Task {
            do {
                let result = try await client.submitOAuthCallback(callbackURL, flowId: flow.flowId)
                if result.status == "success" {
                    await finishReauth(flow, errorMessage: nil)
                } else {
                    showError("Sign-in callback was rejected: \(result.errorMessage ?? "unknown error")")
                    presentReauthInstructions(flow)
                }
            } catch {
                showError("Could not submit the callback URL: \(error.localizedDescription)")
                presentReauthInstructions(flow)
            }
        }
    }

    private func pollReauth(_ flow: ReauthFlow) async {
        var consecutiveFailures = 0
        while !Task.isCancelled, Date() < flow.expiresAt {
            try? await Task.sleep(nanoseconds: UInt64(flow.intervalSeconds) * 1_000_000_000)
            guard !Task.isCancelled, reauthFlows[flow.accountId] === flow else {
                return
            }
            do {
                let status = try await client.oauthStatus(flowId: flow.flowId)
                consecutiveFailures = 0
                switch oauthFlowOutcome(status.status) {
                case .pending:
                    continue
                case .success:
                    // Same as the dashboard: confirm completion for the specific flow.
                    _ = try? await client.completeOAuth(flowId: flow.flowId, deviceAuthId: flow.deviceAuthId, userCode: flow.userCode)
                    await finishReauth(flow, errorMessage: nil)
                    return
                case .error:
                    await finishReauth(flow, errorMessage: status.errorMessage ?? "Sign-in failed.")
                    return
                }
            } catch ClientError.unauthorized {
                await finishReauth(flow, errorMessage: "Dashboard session expired. Log in again and retry.")
                return
            } catch {
                consecutiveFailures += 1
                if consecutiveFailures >= 5 {
                    await finishReauth(flow, errorMessage: "Lost contact with the server: \(error.localizedDescription)")
                    return
                }
            }
        }
        if !Task.isCancelled {
            await finishReauth(flow, errorMessage: "Sign-in timed out. Start again from the account badge.")
        }
    }

    private func finishReauth(_ flow: ReauthFlow, errorMessage: String?) async {
        // Both the poller and a manual callback can finish a flow; only the first one wins.
        guard reauthFlows[flow.accountId] === flow else {
            return
        }
        reauthFlows.removeValue(forKey: flow.accountId)
        accountMutations.removeValue(forKey: flow.accountId)
        if activeReauthPromptAccountId == flow.accountId {
            NSApp.abortModal()
            // Let the aborted modal session unwind before showing the result alert.
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        await refreshWhenIdle(menuWasOpen: isMenuOpen)
        if let errorMessage {
            showError("Re-authentication for \(flow.accountName) failed: \(errorMessage)")
        } else {
            showInfo(title: "Re-authenticated", message: "\(flow.accountName) is signed in again.")
        }
    }

    private func cancelReauth(_ flow: ReauthFlow) {
        guard reauthFlows[flow.accountId] === flow else {
            return
        }
        // No server-side cancel endpoint exists; the pending flow expires by TTL.
        flow.pollTask?.cancel()
        reauthFlows.removeValue(forKey: flow.accountId)
        accountMutations.removeValue(forKey: flow.accountId)
        rebuildMenu(updateVisiblePanel: isMenuOpen)
    }

    private func cancelAllReauthFlows() {
        for flow in Array(reauthFlows.values) {
            cancelReauth(flow)
        }
    }

    // MARK: - Helpers

    private func account(withId accountId: String) -> AccountSummary? {
        overview?.accounts.first { $0.accountId == accountId }
    }

    /// Runs `work` after the status menu has finished tracking, so modal alerts don't fight the open menu.
    private func afterMenuCloses(_ work: @escaping @MainActor () -> Void) {
        statusItem.menu?.cancelTracking()
        RunLoop.main.perform(inModes: [.default]) {
            Task { @MainActor in
                work()
            }
        }
    }

    @objc private func openDashboard() {
        NSWorkspace.shared.open(settings.baseURL)
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            case .notRegistered, .notFound:
                try service.register()
            @unknown default:
                try service.register()
            }
            settingsWindow?.reload()
        } catch {
            settingsWindow?.reload()
            showError("Could not update Launch at Login: \(error.localizedDescription)")
        }
    }

    private func applyServerURL(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host != nil else {
            showError("Enter a full URL such as http://127.0.0.1:2455.")
            settingsWindow?.reload()
            return
        }
        guard trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/")) != settings.baseURLString else {
            return
        }
        settings.baseURLString = trimmed
        serverRuntime = nil
        serverUpdateVersion = nil
        serverReleaseURL = nil
        lastServerVersionCheck = nil
        offlineSince = nil
        cancelAllReauthFlows()
        notifier.reset()
        overview = nil
        client = CodexLBClient(settings: settings)
        autoLoginAttemptedForURL = nil
        Task {
            await refresh()
        }
    }

    @objc private func loginAdmin() {
        guard let password = promptText(
            title: "Admin login",
            message: "Enter the codex-lb dashboard password.",
            defaultValue: "",
            secure: true
        ) else {
            return
        }
        Task {
            do {
                let baseURL = settings.baseURLString
                let session = try await client.loginPassword(password)
                if session.totpRequiredOnLogin {
                    guard let code = promptText(
                        title: "TOTP required",
                        message: "Enter the dashboard TOTP code.",
                        defaultValue: "",
                        secure: false
                    ) else {
                        return
                    }
                    _ = try await client.verifyTotp(code)
                }
                let status = DashboardPasswordStore.save(password, role: .admin, for: baseURL)
                settings.setLoginRole(.admin, for: baseURL)
                await refresh()
                if status != errSecSuccess {
                    showError("Admin login succeeded, but the password could not be saved in Keychain (error \(status)).")
                }
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    @objc private func loginGuest() {
        guard let password = promptText(
            title: "Guest login",
            message: "Enter guest password, or leave blank for passwordless guest access.",
            defaultValue: "",
            secure: true
        ) else {
            return
        }
        Task {
            do {
                let baseURL = settings.baseURLString
                _ = try await client.loginGuest(password: password.isEmpty ? nil : password)
                let status = password.isEmpty
                    ? DashboardPasswordStore.delete(.guest, for: baseURL)
                    : DashboardPasswordStore.save(password, role: .guest, for: baseURL)
                settings.setLoginRole(.guest, for: baseURL)
                await refresh()
                if status != errSecSuccess {
                    showError("Guest login succeeded, but its Keychain entry could not be updated (error \(status)).")
                }
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    /// Ends the dashboard session. Saved Keychain passwords stay (use Forget Saved Login), but automatic
    /// sign-in is suppressed until the next manual login so the app doesn't sign straight back in.
    @objc private func signOut() {
        Task {
            do {
                try await client.logout()
            } catch {
                showError("Could not sign out: \(error.localizedDescription)")
                return
            }
            for cookie in HTTPCookieStorage.shared.cookies(for: settings.baseURL) ?? [] {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            }
            autoLoginAttemptedForURL = settings.baseURLString
            authSession = nil
            await refresh()
        }
    }

    @objc private func forgetSavedLogin() {
        let baseURL = settings.baseURLString
        let statuses = [DashboardPasswordStore.delete(.admin, for: baseURL), DashboardPasswordStore.delete(.guest, for: baseURL)]
        settingsWindow?.reload()
        if let failure = statuses.first(where: { $0 != errSecSuccess }) {
            showError("Could not remove the saved login from Keychain (error \(failure)).")
        } else {
            showInfo(title: "Saved login removed", message: "Passwords for \(baseURL) were removed from Keychain. The current session stays signed in until it expires.")
        }
    }

    // MARK: - Account list

    @objc private func cycleAccountSort() {
        settings.accountSort = settings.accountSort.next
        rebuildMenu(updateVisiblePanel: isMenuOpen)
    }

    @objc private func toggleAccountFilter() {
        settings.accountFilter = settings.accountFilter == .all ? .attention : .all
        rebuildMenu(updateVisiblePanel: isMenuOpen)
    }

    private func accountContextMenu(_ accountId: String) -> NSMenu? {
        guard let account = account(withId: accountId) else {
            return nil
        }
        let menu = NSMenu()
        let header = NSMenuItem(title: accountTitle(account), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        func item(_ title: String, _ selector: Selector, symbol: String, enabled: Bool = true) -> NSMenuItem {
            let menuItem = NSMenuItem(title: title, action: enabled ? selector : nil, keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = accountId
            menuItem.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menuItem.isEnabled = enabled
            return menuItem
        }
        menu.addItem(item("Open in Dashboard", #selector(openAccountInDashboard(_:)), symbol: "safari"))
        menu.addItem(item("Copy Email", #selector(copyAccountEmail(_:)), symbol: "envelope", enabled: !account.email.isEmpty))
        menu.addItem(item("Copy Account ID", #selector(copyAccountID(_:)), symbol: "number"))
        let canWrite = authSession?.role == "admin" && offlineSince == nil && accountMutations[accountId] == nil
        menu.addItem(.separator())
        menu.addItem(item("Rename...", #selector(renameAccount(_:)), symbol: "pencil", enabled: canWrite))
        let warmup = item("Limit Warm-up", #selector(toggleAccountWarmup(_:)), symbol: "flame", enabled: canWrite)
        warmup.state = account.limitWarmupEnabled == true ? .on : .off
        menu.addItem(warmup)
        let credits = account.availableResetCredits ?? 0
        if credits > 0 {
            menu.addItem(item("Use Reset Credit...", #selector(useResetCreditFromMenu(_:)), symbol: "arrow.counterclockwise",
                              enabled: canWrite && canRedeemResetCredit(status: account.status, availableCount: credits)))
        }
        if accountNeedsReauthentication(account.status) {
            menu.addItem(item("Re-authenticate...", #selector(reauthFromMenu(_:)), symbol: "person.badge.key", enabled: canWrite))
        }
        if authSession?.role != "admin" {
            menu.addItem(.separator())
            let hint = NSMenuItem(title: "Admin login required to change accounts", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }
        return menu
    }

    private func showAccountMenu(_ accountId: String) {
        afterMenuCloses { [weak self] in
            guard let self, let menu = self.accountContextMenu(accountId), let button = self.statusItem.button else {
                return
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        }
    }

    @objc private func openAccountInDashboard(_ sender: NSMenuItem) {
        guard let accountId = sender.representedObject as? String,
              var components = URLComponents(url: settings.baseURL, resolvingAgainstBaseURL: false) else {
            return
        }
        components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path) + "/accounts"
        components.queryItems = [URLQueryItem(name: "selected", value: accountId)]
        if let url = components.url {
            statusItem.menu?.cancelTracking()
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func copyAccountEmail(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let account = account(withId: id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(account.email, forType: .string)
    }

    @objc private func copyAccountID(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(id, forType: .string)
    }

    @objc private func renameAccount(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let account = account(withId: id) else { return }
        afterMenuCloses { [weak self] in
            guard let self, let value = self.promptText(
                title: "Rename \(accountTitle(account))",
                message: "Set a display alias for \(account.email). Leave empty to use the account name.",
                defaultValue: account.alias ?? "",
                secure: false
            ) else {
                return
            }
            let alias = value.isEmpty ? nil : String(value.prefix(255))
            self.performAccountMutation(accountId: id, mutation: .alias(alias))
        }
    }

    @objc private func toggleAccountWarmup(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let account = account(withId: id) else { return }
        performAccountMutation(accountId: id, mutation: .limitWarmup(!(account.limitWarmupEnabled ?? false)))
    }

    @objc private func useResetCreditFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        afterMenuCloses { [weak self] in
            self?.confirmAndRedeemResetCredit(accountId: id)
        }
    }

    @objc private func reauthFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        afterMenuCloses { [weak self] in
            self?.presentRecoveryOptions(accountId: id)
        }
    }

    // MARK: - Global shortcut

    private func updateGlobalHotKey() {
        if settings.globalHotKeyEnabled {
            if hotKey == nil {
                hotKey = GlobalHotKey { [weak self] in
                    NSApp.activate(ignoringOtherApps: true)
                    self?.statusItem.button?.performClick(nil)
                }
                if hotKey == nil {
                    showError("\(GlobalHotKey.displayString) is already used by another app.")
                }
            }
        } else {
            hotKey = nil
        }
    }

    // MARK: - Settings

    @objc private func openSettings() {
        afterMenuCloses { [weak self] in
            guard let self else { return }
            if self.settingsWindow == nil {
                self.settingsWindow = SettingsWindowController(settings: self.settings) { [weak self] change in
                    self?.handleSettingsChange(change)
                }
            }
            self.settingsWindow?.show(appVersion: self.updater.currentVersion)
            self.lastServerVersionCheck = nil
            Task { await self.checkServerVersionIfDue() }
        }
    }

    private func handleSettingsChange(_ change: SettingsChange) {
        switch change {
        case .serverURL(let value):
            applyServerURL(value)
        case .launchAtLogin:
            toggleLaunchAtLogin()
        case .notifications(let enabled):
            setNotifications(enabled)
        case .display:
            updateStatusTitle()
        case .menuContent(let periodChanged):
            if periodChanged {
                Task { await refreshWhenIdle(menuWasOpen: false) }
            } else {
                rebuildMenu()
            }
        case .checkForUpdates:
            Task { await checkForUpdates(userInitiated: true) }
        case .checkServerVersion:
            lastServerVersionCheck = nil
            Task { await checkServerVersionIfDue() }
        case .appearance:
            applyAppearance()
        case .hotKey:
            updateGlobalHotKey()
        case .forgetSavedLogin:
            forgetSavedLogin()
        }
    }

    private func applyAppearance() {
        switch settings.theme {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        VisualStyle.intensity = CGFloat(surfaceIntensity(brightness: settings.brightness))
        rebuildMenu(updateVisiblePanel: isMenuOpen)
    }

    /// Accessory apps have no visible main menu, but its key equivalents still route Cmd-C/V/X/A/Z
    /// to text fields (server URL, passwords, OAuth callback URL).
    private func installEditMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    // MARK: - App updates

    @objc private func checkForUpdatesManually() {
        afterMenuCloses { [weak self] in
            Task { await self?.checkForUpdates(userInitiated: true) }
        }
    }

    @objc private func installAvailableUpdate() {
        afterMenuCloses { [weak self] in
            guard let self, let update = self.availableUpdate else { return }
            self.promptForUpdate(update, userInitiated: true)
        }
    }

    private func checkForUpdates(userInitiated: Bool) async {
        guard userInitiated || settings.autoCheckUpdates, !isInstallingUpdate else {
            return
        }
        do {
            let update = try await updater.checkForUpdate()
            availableUpdate = update
            rebuildMenu(updateVisiblePanel: isMenuOpen)
            guard let update else {
                if userInitiated {
                    showInfo(title: "You're up to date", message: "Codex LB Status v\(updater.currentVersion) is the latest version.")
                }
                return
            }
            // Automatic checks respect "Skip This Version"; the menu item still offers it.
            if userInitiated || settings.skippedAppVersion != update.version {
                promptForUpdate(update, userInitiated: userInitiated)
            }
        } catch {
            if userInitiated {
                showError("Could not check for updates: \(error.localizedDescription)")
            }
        }
    }

    private func promptForUpdate(_ update: AppUpdater.Update, userInitiated: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Codex LB Status v\(update.version) is available"
        var notes = (update.release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.count > 900 {
            notes = String(notes.prefix(900)) + "..."
        }
        let blocker = updater.installBlocker()
        alert.informativeText = [
            "You have v\(updater.currentVersion).",
            notes.isEmpty ? nil : notes,
            blocker,
        ].compactMap { $0 }.joined(separator: "\n\n")
        alert.addButton(withTitle: blocker == nil ? "Install and Relaunch" : "Open Download Page")
        alert.addButton(withTitle: "Later")
        if !userInitiated {
            alert.addButton(withTitle: "Skip This Version")
        }
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if blocker == nil {
                Task { await installUpdate(update) }
            } else {
                NSWorkspace.shared.open(update.release.htmlUrl)
            }
        case .alertThirdButtonReturn:
            settings.skippedAppVersion = update.version
        default:
            break
        }
    }

    private func installUpdate(_ update: AppUpdater.Update) async {
        guard !isInstallingUpdate else {
            return
        }
        isInstallingUpdate = true
        let progress = UpdateProgressWindow(title: "Updating Codex LB Status")
        progress.show()
        do {
            try await updater.install(update) { message in
                progress.update(message)
            }
        } catch {
            progress.close()
            isInstallingUpdate = false
            let alert = NSAlert()
            alert.messageText = "Update failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open Download Page")
            alert.addButton(withTitle: "Close")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(update.release.htmlUrl)
            }
        }
    }

    // MARK: - codex-lb server updates

    /// Prefers the server's own check (`/api/runtime/version`, which also works for remote servers);
    /// falls back to GitHub Releases vs the `X-App-Version` header on servers without that endpoint.
    /// Runs at most hourly and notifies once per new server release.
    private func checkServerVersionIfDue() async {
        if let lastServerVersionCheck, Date().timeIntervalSince(lastServerVersionCheck) < 3_600 {
            return
        }
        lastServerVersionCheck = Date()
        var current: String?
        var latest: String?
        var source = "server"
        if let runtime = try? await client.getRuntimeVersion() {
            serverRuntime = runtime
            current = runtime.currentVersion
            latest = runtime.latestVersion
            if runtime.latestVersion == nil {
                source = "GitHub"
            }
        } else {
            current = client.serverVersion
            source = "GitHub"
        }
        if latest == nil, current != nil, let release = try? await updater.latestReleaseTag(repo: "Soju06/codex-lb") {
            latest = release.tag
            serverReleaseURL = release.url
        }
        guard let current else {
            settingsWindow?.setServerStatus("Server version unavailable")
            return
        }
        let normalizedLatest = latest.map { $0.hasPrefix("v") ? String($0.dropFirst()) : $0 }
        let newer = normalizedLatest.flatMap { isNewerVersion($0, than: current) ? $0 : nil }
            ?? (serverRuntime?.updateAvailable == true ? normalizedLatest : nil)
        serverUpdateVersion = newer
        rebuildMenu(updateVisiblePanel: isMenuOpen)
        let checked = DateFormatters.timeOnly.string(from: Date())
        if let newer {
            settingsWindow?.setServerStatus("v\(current) · v\(newer) available (\(source), \(checked))")
            if settings.notifiedServerVersion != newer {
                settings.notifiedServerVersion = newer
                notifier.postServerUpdate(current: current, latest: newer)
            }
        } else if normalizedLatest != nil {
            settingsWindow?.setServerStatus("v\(current) · up to date (\(source), \(checked))")
        } else {
            settingsWindow?.setServerStatus("v\(current) · latest version unknown")
        }
    }

    @objc private func openServerRelease() {
        let fallback = "https://github.com/Soju06/codex-lb/releases/latest"
        if let url = serverRuntime?.releaseUrl.flatMap(URL.init(string:)) ?? serverReleaseURL ?? URL(string: fallback) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func promptText(title: String, message: String, defaultValue: String, secure: Bool) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let field: NSTextField = secure
            ? NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
            : NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field
        // Lay out first so the accessory field (not a button) gets initial focus (PR #3).
        alert.layout()
        alert.window.initialFirstResponder = field

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            return nil
        }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func showError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Codex LB Status"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showInfo(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Confirmation where Return/Escape both choose Cancel, so a stray keypress can't trigger the action.
    private func confirmDestructive(title: String, message: String, confirmTitle: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        let confirm = alert.addButton(withTitle: confirmTitle)
        confirm.hasDestructiveAction = true
        confirm.keyEquivalent = ""
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmRetry(title: String, message: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Close")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func actionItem(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func toggleNotifications() {
        setNotifications(!settings.notificationsEnabled)
    }

    private func setNotifications(_ enable: Bool) {
        Task {
            let granted = await notifier.setEnabled(enable)
            settingsWindow?.reload()
            if enable && !granted {
                showError("Notifications are blocked. Allow \"Codex LB Status\" in System Settings > Notifications.")
            }
        }
    }

    /// Small caption under Quit: "Status Bar v0.3.1 · codex-lb v1.24.0". Not selectable.
    private func versionFooterItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.identifier = serverVersionMenuItemIdentifier
        item.view = VersionFooterView(text: versionFooterText())
        return item
    }

    private func versionFooterText() -> String {
        var parts = ["Status Bar v\(updater.currentVersion)"]
        if let server = (serverRuntime?.currentVersion ?? client.serverVersion)?.trimmingCharacters(in: .whitespaces), !server.isEmpty {
            parts.append("codex-lb v\(server.hasPrefix("v") ? String(server.dropFirst()) : server)")
        }
        return parts.joined(separator: " · ")
    }

}

private func formatPercent(_ value: Double) -> String {
    "\(Int(round(value)))%"
}

private func formatOptionalPercent(_ value: Double?) -> String {
    guard let value else {
        return "--"
    }
    return formatPercent(value)
}

private func relativeTime(_ date: Date) -> String {
    let seconds = Int(date.timeIntervalSinceNow)
    if seconds <= 0 {
        return "now"
    }
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

@main
private enum CodexLBStatusBarMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
