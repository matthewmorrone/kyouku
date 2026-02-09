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
