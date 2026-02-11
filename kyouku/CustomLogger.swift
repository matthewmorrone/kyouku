import Foundation
import OSLog

/// Project-wide logger wrapper.
///
/// - Provides a single API surface for console logging.
/// - Captures call-site context automatically (file/line/function) via default args.
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

    static let shared = CustomLogger()

    private let logger: Logger
    private let dateFormatter: DateFormatter
    private let timestampFormat: String
    
    init(
        subsystem: String = Bundle.main.bundleIdentifier ?? "kyouku",
        category: String = "CustomLogger",
        timestampFormat: String? = nil
    ) {
        self.timestampFormat = timestampFormat ?? "HH:mm:ss.SSS"
        self.dateFormatter = DateFormatter()
        self.dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        self.dateFormatter.timeZone = TimeZone.autoupdatingCurrent
        self.dateFormatter.dateFormat = self.timestampFormat
        self.logger = Logger(subsystem: subsystem, category: category)
    }

    // MARK: - Primary API

    func log(
        _ message: @autoclosure () -> String,
        level: Level = .default,
        file: StaticString = #fileID,
        line: UInt = #line,
        function: StaticString = #function
    ) {
        let rendered = Self.render(
            message(),
            file: file,
            line: line,
            function: function,
            timestamp: currentTimestampString()
        )
        Self.emit(rendered, level: level, logger: logger)
    }
    
    func debug(
        _ message: @autoclosure () -> String,
        file: StaticString = #fileID,
        line: UInt = #line,
        function: StaticString = #function
    ) {
        log(message(), level: .debug, file: file, line: line, function: function)
    }
    
    func info(
        _ message: @autoclosure () -> String,
        file: StaticString = #fileID,
        line: UInt = #line,
        function: StaticString = #function
    ) {
        log(message(), level: .info, file: file, line: line, function: function)
    }
    
    func error(
        _ message: @autoclosure () -> String,
        file: StaticString = #fileID,
        line: UInt = #line,
        function: StaticString = #function
    ) {
        log(message(), level: .error, file: file, line: line, function: function)
    }

    /// Emits a pipeline log line with fixed-width context/stage columns so stages align visually.
    func pipeline(
        context: String,
        stage: String,
        _ message: @autoclosure () -> String,
        level: Level = .info,
        file: StaticString = #fileID,
        line: UInt = #line,
        function: StaticString = #function
    ) {
        let full = "\(Self.pipelinePrefix(context: context, stage: stage)) \(message())"
        log(full, level: level, file: file, line: line, function: function)
    }
    
        /// Always writes to stdout via Swift's `print`, independent of OSLog.
    func print(
        _ message: @autoclosure () -> String,
        file: StaticString = #fileID,
        line: UInt = #line,
        function: StaticString = #function
    ) {
        Swift.print(Self.render(
            message(),
            file: file,
            line: line,
            function: function,
            timestamp: currentTimestampString()
        ))
    }

    /// Writes the string as-is to stdout (no timestamp/call-site decoration).
    func raw(_ message: @autoclosure () -> String) {
        Swift.print(message())
    }

    /// Best-effort console clear for startup diagnostics.
    /// Uses ANSI clear/home plus optional blank lines as fallback spacing.
    func clearConsole(extraBlankLines: Int = 0) {
        // ANSI escape: clear screen + move cursor to home.
        let clearSequence = "\u{001B}[2J\u{001B}[H"
        Swift.print(clearSequence, terminator: "")
        if extraBlankLines > 0 {
            for _ in 0..<extraBlankLines {
                Swift.print("")
            }
        }
    }

    // MARK: - Internals
    
    private func currentTimestampString() -> String {
        return dateFormatter.string(from: Date())
    }
    
    private static func render(_ message: String, file: StaticString, line: UInt, function: StaticString, timestamp: String) -> String {
        "[\(timestamp)] [\(file):\(line)] \(function): \(message)"
    }

    private static func rightPad(_ value: String, minWidth: Int) -> String {
        guard minWidth > 0 else { return value }
        let length = value.count
        guard length < minWidth else { return value }
        return value + String(repeating: " ", count: minWidth - length)
    }

    private static func pipelinePrefix(context: String, stage: String) -> String {
        let contextColumn = rightPad(context, minWidth: 16)
        let stageColumn = rightPad(stage, minWidth: 8)
        return "[Pipeline] [\(contextColumn)] [\(stageColumn)]"
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
