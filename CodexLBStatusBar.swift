import Cocoa
import Foundation
import ServiceManagement
import UserNotifications

private let defaultBaseURL = "http://127.0.0.1:2455"
private let appDisplayName = "Codex LB Status"
private let serverVersionMenuItemIdentifier = NSUserInterfaceItemIdentifier("codexLBServerVersion")

private final class SettingsStore {
    private let defaults = UserDefaults.standard
    private let baseURLKey = "codexLBBaseURL"
    private let notificationsKey = "codexLBNotificationsEnabled"

    var baseURLString: String {
        get {
            defaults.string(forKey: baseURLKey) ?? defaultBaseURL
        }
        set {
            defaults.set(Self.normalizedBaseURL(newValue), forKey: baseURLKey)
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

    private static func normalizedBaseURL(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return defaultBaseURL
        }
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
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
        try await request(path: "/api/dashboard/overview?timeframe=7d")
    }

    func loginPassword(_ password: String) async throws -> AuthSession {
        let payload = try JSONSerialization.data(withJSONObject: ["password": password], options: [])
        return try await request(path: "/api/dashboard-auth/password/login", method: "POST", body: payload)
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

private enum VisualStyle {
    static let menuWidth: CGFloat = 440
    static let contentWidth: CGFloat = 416
    static let accountCardHeight: CGFloat = 152
    static let cardRadius: CGFloat = 10
    static let cardBackground = NSColor(calibratedWhite: 0.12, alpha: 1)
    static let panelBackground = NSColor(calibratedWhite: 0.04, alpha: 1)
    static let border = NSColor(calibratedWhite: 0.20, alpha: 1)
    static let textPrimary = NSColor(calibratedWhite: 0.94, alpha: 1)
    static let textSecondary = NSColor(calibratedWhite: 0.67, alpha: 1)
    static let textMuted = NSColor(calibratedWhite: 0.50, alpha: 1)
    static let track = NSColor(calibratedWhite: 0.24, alpha: 1)
    static let trackDim = NSColor(calibratedWhite: 0.16, alpha: 1)
    static let green = NSColor(calibratedRed: 0.07, green: 0.78, blue: 0.45, alpha: 1)
    static let greenDim = NSColor(calibratedRed: 0.02, green: 0.28, blue: 0.20, alpha: 1)
    static let amber = NSColor(calibratedRed: 0.96, green: 0.62, blue: 0.04, alpha: 1)
    static let amberDim = NSColor(calibratedRed: 0.30, green: 0.20, blue: 0.03, alpha: 1)
    static let red = NSColor(calibratedRed: 1.00, green: 0.22, blue: 0.34, alpha: 1)
    static let redDim = NSColor(calibratedRed: 0.36, green: 0.08, blue: 0.11, alpha: 1)
    static let blue = NSColor(calibratedRed: 0.19, green: 0.50, blue: 0.78, alpha: 1)
    static let blueDim = NSColor(calibratedRed: 0.05, green: 0.22, blue: 0.30, alpha: 1)
}

private class RoundedPanelView: NSView {
    init(width: CGFloat, height: CGFloat, background: NSColor = VisualStyle.panelBackground) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        wantsLayer = true
        layer?.backgroundColor = background.cgColor
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
        layer?.backgroundColor = color.cgColor
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

        var background: NSColor {
            switch self {
            case .neutral:
                return NSColor(calibratedWhite: 0.10, alpha: 1)
            case .active:
                return VisualStyle.greenDim
            case .warning:
                return VisualStyle.amberDim
            case .danger:
                return VisualStyle.redDim
            case .burnFirst:
                return VisualStyle.amberDim
            case .preserve:
                return VisualStyle.blueDim
            }
        }

        var border: NSColor {
            switch self {
            case .neutral:
                return NSColor(calibratedWhite: 0.24, alpha: 1)
            case .active:
                return NSColor(calibratedRed: 0.02, green: 0.45, blue: 0.31, alpha: 1)
            case .warning:
                return NSColor(calibratedRed: 0.55, green: 0.36, blue: 0.03, alpha: 1)
            case .danger:
                return NSColor(calibratedRed: 0.55, green: 0.12, blue: 0.18, alpha: 1)
            case .burnFirst:
                return NSColor(calibratedRed: 0.55, green: 0.36, blue: 0.03, alpha: 1)
            case .preserve:
                return NSColor(calibratedRed: 0.08, green: 0.42, blue: 0.56, alpha: 1)
            }
        }

        var text: NSColor {
            switch self {
            case .neutral:
                return VisualStyle.textSecondary
            case .active:
                return VisualStyle.green
            case .warning:
                return VisualStyle.amber
            case .danger:
                return VisualStyle.red
            case .burnFirst:
                return VisualStyle.amber
            case .preserve:
                return NSColor(calibratedRed: 0.20, green: 0.72, blue: 0.92, alpha: 1)
            }
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
        layer?.backgroundColor = tone.background.cgColor
        layer?.borderColor = tone.border.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 13

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        var markerWidth: CGFloat = 0
        if let symbolName {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            image.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: text)
            image.contentTintColor = tone.text
            image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            NSLayoutConstraint.activate([
                image.widthAnchor.constraint(equalToConstant: 12),
                image.heightAnchor.constraint(equalToConstant: 12),
            ])
            stack.addArrangedSubview(image)
            markerWidth = 18
        } else if dot {
            stack.addArrangedSubview(DotView(color: tone.text, size: 7))
            markerWidth = 13
        }
        let label = makeLabel(text, size: 12, weight: .medium, color: tone.text)
        stack.addArrangedSubview(label)
        let leadingPadding: CGFloat = markerWidth > 0 ? 10 : 12
        let contentWidth = label.intrinsicContentSize.width + leadingPadding + markerWidth + 12

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            widthAnchor.constraint(equalToConstant: ceil(contentWidth)),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingPadding),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
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
        layer?.borderWidth = 1.6
        layer?.borderColor = tone.text.cgColor
        layer?.backgroundColor = (tone.background.blended(withFraction: 0.12, of: tone.text) ?? tone.background).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.borderWidth = 1
        layer?.borderColor = tone.border.cgColor
        layer?.backgroundColor = tone.background.cgColor
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

/// Compact text button used for the reset-credit indicator in the card's top-right corner.
private final class ResetCreditButton: NSButton {
    let accountId: String

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
        let symbol = NSImage(systemSymbolName: "arrow.counterclockwise.circle.fill", accessibilityDescription: nil)
        image = symbol?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        imagePosition = enabled ? .imageLeading : .noImage
        contentTintColor = VisualStyle.blue
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: VisualStyle.blue,
        ])
        setAccessibilityLabel(text)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

private final class QuotaProgressView: NSView {
    private let percent: Double?

    init(percent: Double?) {
        self.percent = percent
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 6)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0, dy: 0)
        let track = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        (percent.map(quotaTrackColor) ?? VisualStyle.trackDim).setFill()
        track.fill()

        guard let percent else {
            return
        }
        let clamped = min(max(percent, 0), 100)
        guard clamped > 0 else {
            return
        }
        let fillWidth = max(4, rect.width * CGFloat(clamped / 100))
        let fillRect = NSRect(x: rect.minX, y: rect.minY, width: min(fillWidth, rect.width), height: rect.height)
        let fill = NSBezierPath(roundedRect: fillRect, xRadius: 3, yRadius: 3)
        quotaColor(percent).setFill()
        fill.fill()
    }
}

private final class QuotaMiniView: NSView {
    init(label: String, remainingPercent: Double?, resetAt: Date?) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let topRow = NSStackView()
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 6
        topRow.translatesAutoresizingMaskIntoConstraints = false

        let name = makeLabel(label, size: 12, weight: .regular, color: VisualStyle.textSecondary)
        let percent = makeLabel(formatOptionalPercent(remainingPercent), size: 12, weight: .semibold, color: VisualStyle.textPrimary)
        percent.alignment = .right
        topRow.addArrangedSubview(name)
        topRow.addArrangedSubview(NSView.spacer())
        topRow.addArrangedSubview(percent)

        let progress = QuotaProgressView(percent: remainingPercent)
        let resetText = resetAt.map { "Reset in \(relativeTime($0))" } ?? "Reset --"
        let reset = makeLabel(resetText, size: 11, weight: .regular, color: VisualStyle.textMuted)

        let stack = NSStackView(views: [topRow, progress, reset])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            topRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progress.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

private final class AccountCardView: NSView {
    init(
        account: AccountSummary,
        canWrite: Bool,
        isRefreshing: Bool,
        mutation: AccountMutation?,
        actionTarget: AnyObject,
        statusAction: Selector,
        routingAction: Selector,
        resetAction: Selector
    ) {
        super.init(frame: NSRect(x: 0, y: 0, width: VisualStyle.contentWidth, height: VisualStyle.accountCardHeight))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = VisualStyle.cardBackground.cgColor
        layer?.borderColor = VisualStyle.border.cgColor
        layer?.borderWidth = 0.8
        layer?.cornerRadius = 8
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
        case .resetCredit:
            resetIsUpdating = true
        case .reauth:
            reauthPending = true
        case nil:
            break
        }

        let title = makeLabel(accountTitle(account), size: 16, weight: .semibold, color: VisualStyle.textPrimary)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let subtitle = makeLabel(accountSubtitle(account), size: 12, weight: .regular, color: VisualStyle.textMuted)
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
        topRow.spacing = 8
        topRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topRow)

        let resetCount = account.availableResetCredits ?? 0
        let resetCreditLabel = compactResetCreditLabel(
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
                button.toolTip = "Use a reset credit (asks for confirmation)"
            }
            return button
        }
        if let resetCreditLabel {
            addSubview(resetCreditLabel)
            NSLayoutConstraint.activate([
                resetCreditLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
                resetCreditLabel.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            ])
        }

        let quotaRow = NSStackView()
        quotaRow.orientation = .horizontal
        quotaRow.alignment = .top
        quotaRow.distribution = .fillEqually
        quotaRow.spacing = 12
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

        let warmupLeft = makeLabel(warmupStatus(account), size: 11, weight: .regular, color: VisualStyle.textMuted)
        let warmupRight = makeLabel(warmupAttempt(account), size: 11, weight: .regular, color: VisualStyle.textMuted)
        warmupRight.alignment = .right
        let bottomRow = NSStackView(views: [warmupLeft, NSView.spacer(), warmupRight])
        bottomRow.orientation = .horizontal
        bottomRow.alignment = .centerY
        bottomRow.spacing = 8
        bottomRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bottomRow)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: VisualStyle.contentWidth),
            heightAnchor.constraint(equalToConstant: VisualStyle.accountCardHeight),
            topRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            topRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            topRow.topAnchor.constraint(equalTo: topAnchor, constant: resetCreditLabel == nil ? 14 : 18),
            quotaRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            quotaRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            quotaRow.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: 18),
            bottomRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            bottomRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            bottomRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
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
        resetAction: Selector
    ) {
        let cardHeight = VisualStyle.accountCardHeight
        let gap: CGFloat = 8
        let headerHeight: CGFloat = 32
        let maxCardsVisible: CGFloat = 4
        let contentHeight = headerHeight + CGFloat(accounts.count) * cardHeight + CGFloat(max(accounts.count - 1, 0)) * gap + 18
        let maxHeight = headerHeight + maxCardsVisible * cardHeight + (maxCardsVisible - 1) * gap + 18
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
            button.contentTintColor = VisualStyle.textSecondary
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 22),
                button.heightAnchor.constraint(equalToConstant: 22),
            ])
            refreshControl = button
        }

        let title = makeLabel("Accounts", size: 15, weight: .bold, color: VisualStyle.textPrimary)
        let accountCount = "\(accounts.filter { $0.status == "active" }.count) active / \(accounts.count) total"
        let refreshStatus = refreshStatusLabel(isRefreshing: isRefreshing, lastRefreshedAt: lastRefreshedAt)
        let count = makeLabel([accountCount, refreshStatus].compactMap { $0 }.joined(separator: " | "), size: 11, color: VisualStyle.textMuted)
        count.alignment = .right

        let header = NSStackView(views: [title, refreshControl, NSView.spacer(), count])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = gap
        stack.translatesAutoresizingMaskIntoConstraints = false

        for account in accounts.sorted(by: accountSort) {
            stack.addArrangedSubview(AccountCardView(
                account: account,
                canWrite: canWrite,
                isRefreshing: isRefreshing,
                mutation: accountMutations[account.accountId],
                actionTarget: accountActionTarget,
                statusAction: statusAction,
                routingAction: routingAction,
                resetAction: resetAction
            ))
        }

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = contentHeight > maxHeight
        scrollView.autohidesScrollers = true
        scrollView.documentView = stack
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            stack.widthAnchor.constraint(equalToConstant: VisualStyle.contentWidth),
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
    imageView.image = NSImage(systemSymbolName: "shield.checkered", accessibilityDescription: "authorized")
    imageView.contentTintColor = VisualStyle.green
    imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
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
        rows.append(QuotaMiniView(label: "5h", remainingPercent: account.usage?.primaryRemainingPercent, resetAt: account.resetAtPrimary))
    }
    if account.windowMinutesSecondary != nil || account.usage?.secondaryRemainingPercent != nil {
        rows.append(QuotaMiniView(label: "Weekly", remainingPercent: account.usage?.secondaryRemainingPercent, resetAt: account.resetAtSecondary))
    }
    if account.windowMinutesMonthly != nil || account.usage?.monthlyRemainingPercent != nil {
        rows.append(QuotaMiniView(label: "Monthly", remainingPercent: account.usage?.monthlyRemainingPercent, resetAt: account.resetAtMonthly))
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setStatusTitle("...")
        notifier.onActivate = { [weak self] in
            self?.statusItem.button?.performClick(nil)
        }
        notifier.configure()
        rebuildMenu()
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
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
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
            authSession = try await client.getSession()
            let fetched = try await client.fetchOverview()
            overview = fetched
            lastRefreshedAt = Date()
            latestError = nil
            updateStatusTitle()
            notifier.process(fetched.accounts)
        } catch ClientError.unauthorized {
            overview = nil
            latestError = "Dashboard login required"
            setStatusTitle("Login")
        } catch {
            overview = nil
            latestError = error.localizedDescription
            setStatusTitle("Error")
        }
    }

    private func setStatusTitle(_ text: String) {
        statusItem.button?.attributedTitle = NSAttributedString(string: text, attributes: [.font: NSFont.menuBarFont(ofSize: 0)])
        statusItem.button?.toolTip = nil
    }

    private func updateStatusTitle() {
        guard let overview else {
            setStatusTitle(latestError == nil ? "Status" : "Error")
            return
        }

        let summary = QuotaSummary(accounts: overview.accounts)
        let segments = statusTitleSegments(
            primary: summary.primary,
            secondary: summary.secondary,
            monthly: summary.monthly,
            activeCount: summary.activeCount,
            totalCount: overview.accounts.count,
            attentionCount: summary.attentionCount
        )
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        let title = NSMutableAttributedString()
        for (index, segment) in segments.enumerated() {
            if index > 0 {
                title.append(NSAttributedString(string: " ", attributes: [.font: font]))
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: font]
            switch segment.kind {
            case .attention:
                attributes[.foregroundColor] = NSColor.systemRed
                attributes[.font] = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .heavy)
            case .quota(let tone):
                attributes[.foregroundColor] = menuBarColor(tone)
            case .count:
                break  // default menu bar text color (adapts to light/dark and highlight)
            }
            title.append(NSAttributedString(string: segment.text, attributes: attributes))
        }
        statusItem.button?.attributedTitle = title

        var tooltip = ["Average remaining across \(summary.countedCount) usable account(s); paused and re-auth accounts are excluded."]
        if summary.attentionCount > 0 {
            tooltip.append("\(summary.attentionCount) account(s) need re-authentication.")
        }
        statusItem.button?.toolTip = tooltip.joined(separator: "\n")
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

        if let overview {
            if !overview.accounts.isEmpty {
                menu.addItem(viewItem(AccountsPanelView(
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
                    resetAction: #selector(resetCreditTapped(_:))
                )))
            } else {
                menu.addItem(viewItem(StatusMessageView(
                    title: appDisplayName,
                    message: "No accounts imported yet.",
                    detail: "Server: \(settings.baseURLString)"
                )))
            }
        } else if let latestError {
            menu.addItem(viewItem(StatusMessageView(
                title: latestError == "Dashboard login required" ? "Login required" : "Codex LB Connection Error",
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
        menu.addItem(actionItem("Open Dashboard", #selector(openDashboard)))
        menu.addItem(actionItem("Set Server URL...", #selector(setServerURL)))
        menu.addItem(launchAtLoginItem())
        menu.addItem(notificationsItem())
        menu.addItem(actionItem("Admin Login...", #selector(loginAdmin)))
        menu.addItem(actionItem("Guest Login...", #selector(loginGuest)))
        menu.addItem(serverVersionItem())
        menu.addItem(.separator())
        menu.addItem(actionItem("Quit", #selector(quit)))
        if updateVisiblePanel,
           let visibleItem = previousMenu?.items.first,
           let container = visibleItem.view as? MenuContentContainerView,
           let updatedView = menu.items.first?.view as? MenuContentContainerView,
           let updatedContent = updatedView.subviews.first {
            container.replaceContent(with: updatedContent)
            previousMenu?.items.first(where: { $0.identifier == serverVersionMenuItemIdentifier })?.title = codexLBVersionLabel(client.serverVersion)
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
            rebuildMenu()
        } catch {
            showError("Could not update Launch at Login: \(error.localizedDescription)")
        }
    }

    @objc private func setServerURL() {
        guard let value = promptText(
            title: "Set codex-lb server",
            message: "Enter the codex-lb dashboard base URL.",
            defaultValue: settings.baseURLString,
            secure: false
        ) else {
            return
        }
        settings.baseURLString = value
        cancelAllReauthFlows()
        notifier.reset()
        overview = nil
        client = CodexLBClient(settings: settings)
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
                await refresh()
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
                _ = try await client.loginGuest(password: password.isEmpty ? nil : password)
                await refresh()
            } catch {
                showError(error.localizedDescription)
            }
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

    private func launchAtLoginItem() -> NSMenuItem {
        let item = actionItem("Launch at Login", #selector(toggleLaunchAtLogin))
        switch SMAppService.mainApp.status {
        case .enabled:
            item.state = .on
        case .requiresApproval:
            item.state = .mixed
            item.toolTip = "Approval required in System Settings"
        case .notRegistered, .notFound:
            item.state = .off
        @unknown default:
            item.state = .off
        }
        return item
    }

    private func notificationsItem() -> NSMenuItem {
        let item = actionItem("Notifications", #selector(toggleNotifications))
        item.state = settings.notificationsEnabled ? .on : .off
        item.toolTip = "Alert when average quota drops below \(quotaAlertThresholds.map { "\(Int($0))%" }.joined(separator: " / ")) or an account needs re-authentication"
        return item
    }

    @objc private func toggleNotifications() {
        let enable = !settings.notificationsEnabled
        Task {
            let granted = await notifier.setEnabled(enable)
            rebuildMenu()
            if enable && !granted {
                showError("Notifications are blocked. Allow \"Codex LB Status\" in System Settings > Notifications.")
            }
        }
    }

    private func serverVersionItem() -> NSMenuItem {
        let item = NSMenuItem(title: codexLBVersionLabel(client.serverVersion), action: nil, keyEquivalent: "")
        item.identifier = serverVersionMenuItemIdentifier
        item.isEnabled = false
        return item
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
