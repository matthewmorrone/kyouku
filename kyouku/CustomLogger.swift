import Foundation
import OSLog

    /// Project-wide logger wrapper.
    ///
    /// - Provides a single API surface for console logging.
    /// - Captures call-site context automatically (file/line/function) via default args.
    /// - Does not depend on `DiagnosticsLogging` and is not wired into the app yet.
final class CustomLogger {
    enum Level: String, CaseIterable, Hashable {
        case debug
        case info
        case notice
        case warning
        case error
        case fault
        case `default`
    }
    
    struct Enablement: Equatable {
        var enabled: Bool
        var enabledLevels: Set<Level>
        var printEnabled: Bool
        
        static let `default` = Enablement(
            enabled: true,
            enabledLevels: Set(Level.allCases),
            printEnabled: true
        )
    }
    
    struct TimerToken: Hashable {
        internal let id: UUID
    }
    
    static let shared = CustomLogger()
    
    static var globallyEnabled: Bool {
        get { shared.isEnabled }
        set { shared.isEnabled = newValue }
    }
    
    private let startTime: CFAbsoluteTime
    private let logger: Logger
    
    private let dateFormatter: DateFormatter
    public var timestampFormat: String
    
    private let enablementLock = NSLock()
    private var enablement: Enablement = .default
    
    private var timers: [TimerToken: CFAbsoluteTime] = [:]
    private var namedTimers: [String: TimerToken] = [:]
    private var counters: [String: Int] = [:]
    
    init(
        subsystem: String = Bundle.main.bundleIdentifier ?? "kyouku",
        category: String = "CustomLogger",
        timestampFormat: String? = nil
    ) {
        self.startTime = CFAbsoluteTimeGetCurrent()
        self.timestampFormat = timestampFormat ?? "HH:mm:ss.SSS"
        self.dateFormatter = DateFormatter()
        self.dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        self.dateFormatter.timeZone = TimeZone.autoupdatingCurrent
        self.dateFormatter.dateFormat = self.timestampFormat
        self.logger = Logger(subsystem: subsystem, category: category)
    }
    
        // MARK: - Enablement
    
    func setEnabled(_ enabled: Bool) {
        enablementLock.lock()
        enablement.enabled = enabled
        enablementLock.unlock()
    }
    
    public var isEnabled: Bool {
        get {
            enablementLock.lock(); defer { enablementLock.unlock() }
            return enablement.enabled
        }
        set {
            enablementLock.lock()
            enablement.enabled = newValue
            enablementLock.unlock()
        }
    }
    
    func setPrintEnabled(_ enabled: Bool) {
        enablementLock.lock()
        enablement.printEnabled = enabled
        enablementLock.unlock()
    }
    
    func setLevelEnabled(_ level: Level, enabled: Bool) {
        enablementLock.lock()
        if enabled {
            enablement.enabledLevels.insert(level)
        } else {
            enablement.enabledLevels.remove(level)
        }
        enablementLock.unlock()
    }
    
    func setEnabledLevels(_ levels: Set<Level>) {
        enablementLock.lock()
        enablement.enabledLevels = levels
        enablementLock.unlock()
    }
    
    func enableAllLogs() {
        enablementLock.lock()
        enablement = .default
        enablementLock.unlock()
    }
    
    func disableAllLogs() {
        enablementLock.lock()
        enablement.enabled = false
        enablementLock.unlock()
    }
    
    func currentEnablement() -> Enablement {
        enablementLock.lock()
        let snapshot = enablement
        enablementLock.unlock()
        return snapshot
    }
    
        // MARK: - Primary API
    
        /// Closure-based form so callers can preserve laziness without `@autoclosure` impedance.
    
    func log<T>(
        _ value: T,
        level: Level = .default,
        file: StaticString = #fileID,
        line: UInt = #line,
        function: StaticString = #function
    ) {
        log(
            String(describing: value),
            level: level,
            file: file,
            line: line,
            function: function
        )
    }
    func log(
        _ message: () -> String,
        level: Level = .default,
        file: StaticString = #fileID,
        line: UInt = #line,
        function: StaticString = #function
    ) {
        enablementLock.lock()
        let snapshot = enablement
        enablementLock.unlock()
        
        guard snapshot.enabled else { return }
        guard snapshot.enabledLevels.contains(level) else { return }
        
        let rendered = Self.render(
            message(),
            file: file,
            line: line,
            function: function,
            timestamp: currentTimestampString()
        )
        Self.emit(rendered, level: level, logger: logger)
    }
    
    func log(
        _ message: @autoclosure () -> String,
        level: Level = .default,
        file: StaticString = #fileID,
        line: UInt = #line,
        function: StaticString = #function
    ) {
        log(message, level: level, file: file, line: line, function: function)
    }
    
    func debug(
        _ message: @autoclosure () -> String,
        file: StaticString = #fileID,
        line: UInt = #line,
        function: StaticString = #function
    ) {
        log(message, level: .debug, file: file, line: line, function: function)
    }
    
    func info(
        _ message: @autoclosure () -> String,
        file: StaticString = #fileID,
        line: UInt = #line,
        function: StaticString = #function
    ) {
        log(message, level: .info, file: file, line: line, function: function)
    }
    
    func notice(
        _ message: @autoclosure () -> String,
        file: StaticString = #fileID,
        line: UInt = #line,
        function: StaticString = #function
    ) {
        log(message, level: .notice, file: file, line: line, function: function)
    }
    
    func warn(
        _ message: @autoclosure () -> String,
        file: StaticString = #fileID,
        line: UInt = #line,
        function: StaticString = #function
    ) {
        log(message, level: .warning, file: file, line: line, function: function)
    }
    
    func error(
        _ message: @autoclosure () -> String,
        file: StaticString = #fileID,
        line: UInt = #line,
        function: StaticString = #function
    ) {
        log(message, level: .error, file: file, line: line, function: function)
    }
    
    func fault(
        _ message: @autoclosure () -> String,
        file: StaticString = #fileID,
        line: UInt = #line,
        function: StaticString = #function
    ) {
        log(message, level: .fault, file: file, line: line, function: function)
    }
    
        /// Always writes to stdout via Swift's `print`, independent of OSLog.
    func print(
        _ message: @autoclosure () -> String,
        file: StaticString = #fileID,
        line: UInt = #line,
        function: StaticString = #function
    ) {
        enablementLock.lock()
        let snapshot = enablement
        enablementLock.unlock()
        
        guard snapshot.enabled else { return }
        guard snapshot.printEnabled else { return }
        
        Swift.print(Self.render(
            message(),
            file: file,
            line: line,
            function: function,
            timestamp: currentTimestampString()
        ))
    }
    
        // MARK: - Timers
    
    @discardableResult
    func startTimer(name: String? = nil) -> TimerToken {
        let token = TimerToken(id: UUID())
        timers[token] = CFAbsoluteTimeGetCurrent()
        if let name {
            namedTimers[name] = token
        }
        return token
    }
    
    @discardableResult
    func endTimer(_ token: TimerToken, name: String? = nil) -> Double? {
        guard let start = timers.removeValue(forKey: token) else { return nil }
        if let name {
            namedTimers[name] = nil
        }
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        return ms
    }
    
    @discardableResult
    func endTimer(named name: String) -> Double? {
        guard let token = namedTimers.removeValue(forKey: name) else { return nil }
        return endTimer(token)
    }
    
    func measure<T>(name: String? = nil, _ block: () throws -> T) rethrows -> (T, Double) {
        let token = startTimer(name: name)
        let result = try block()
        let ms = endTimer(token) ?? 0
        return (result, ms)
    }
    
    func measureAsync<T>(name: String? = nil, _ operation: () async throws -> T) async rethrows -> (T, Double) {
        let token = startTimer(name: name)
        let result = try await operation()
        let ms = endTimer(token) ?? 0
        return (result, ms)
    }
    
        // MARK: - Counters
    
    func incrementCounter(_ name: String, by delta: Int = 1) {
        counters[name, default: 0] += delta
    }
    
    func setCounter(_ name: String, value: Int) {
        counters[name] = value
    }
    
    func getCounter(_ name: String) -> Int {
        counters[name, default: 0]
    }
    
        // MARK: - Internals
    
    private func currentTimestampString() -> String {
        return dateFormatter.string(from: Date())
    }
    
    private static func render(_ message: String, file: StaticString, line: UInt, function: StaticString, timestamp: String) -> String {
        "[\(timestamp)] [\(file):\(line)] \(function): \(message)"
    }
    
    private static func emit(_ message: String, level: Level, logger: Logger) {
        switch level {
        case .debug:
            logger.debug("\(message, privacy: .public)")
        case .info:
            logger.info("\(message, privacy: .public)")
        case .notice:
            logger.notice("\(message, privacy: .public)")
        case .warning:
                // OSLog has no dedicated "warning"; map to notice.
            logger.notice("\(message, privacy: .public)")
        case .error:
            logger.error("\(message, privacy: .public)")
        case .fault:
            logger.fault("\(message, privacy: .public)")
        case .default:
            logger.log("\(message, privacy: .public)")
        }
    }
}
