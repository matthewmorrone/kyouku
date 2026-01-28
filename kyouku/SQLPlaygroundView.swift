import SwiftUI
import UIKit

private struct ReadOnlySelectableTextView: UIViewRepresentable {
    let text: String
    let font: UIFont

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        view.textContainer.lineFragmentPadding = 0

        // Allow horizontal scrolling for long result lines.
        view.textContainer.widthTracksTextView = false
        view.textContainer.lineBreakMode = .byClipping
        view.textContainer.size = CGSize(width: 20000, height: CGFloat.greatestFiniteMagnitude)

        view.alwaysBounceVertical = true
        view.alwaysBounceHorizontal = true
        view.showsVerticalScrollIndicator = true
        view.showsHorizontalScrollIndicator = true

        view.text = text
        view.font = font
        view.textColor = .appTextPrimary
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
        if uiView.font != font {
            uiView.font = font
        }
        if uiView.textColor != .appTextPrimary {
            uiView.textColor = .appTextPrimary
        }
    }
}

struct SQLPlaygroundView: View {
    @State private var sqlText: String = ""
    @State private var outputText: String = ""
    @State private var errorMessage: String? = nil
    @State private var isRunning: Bool = false

    @State private var tableNames: [String] = []
    @State private var selectedTable: String = ""
    @State private var isLoadingTables: Bool = false
    @State private var tablesErrorMessage: String? = nil

    @FocusState private var isEditorFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            let topHeight = geometry.size.height * 0.40
            let bottomHeight = geometry.size.height * 0.40

            VStack(spacing: 8) {
                ReadOnlySelectableTextView(
                    text: displayText,
                    font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
                )
                .frame(height: topHeight)
                .background(Color.appSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.appBorder, lineWidth: 1)
                )
                .padding([.horizontal, .top])

                tablePickerBar
                    .padding(.horizontal)

                TextEditor(text: $sqlText)
                    .font(.system(size: 13, design: .monospaced))
                    .focused($isEditorFocused)
                    .frame(height: bottomHeight)
                    .padding(8)
                    .background(Color.appSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.appBorder, lineWidth: 1)
                    )
                        .padding([.horizontal, .bottom])
            }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle("SQL Playground")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    if isRunning {
                        ProgressView()
                    }
                    Button("Run") {
                        isEditorFocused = false
                        Task { await runCurrentSQL() }
                    }
                    .disabled(sqlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isRunning)
                }
            }
            .task {
                await reloadTablesIfNeeded()
            }
        }
        .appThemedRoot()
    }

    private var tablePickerBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Picker("Table", selection: $selectedTable) {
                    Text("Insert SELECT…").tag("")
                    ForEach(tableNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .pickerStyle(.menu)
                .disabled(tableNames.isEmpty)
                .onChange(of: selectedTable) { _, newValue in
                    guard newValue.isEmpty == false else { return }
                    Task {
                        await appendSelectStatement(forTableNamed: newValue)
                        selectedTable = ""
                    }
                }

                Spacer(minLength: 0)

                if isLoadingTables {
                    ProgressView()
                }

                Button("Refresh") {
                    Task { await reloadTables() }
                }
                .buttonStyle(.bordered)
            }

            if let tablesErrorMessage, tablesErrorMessage.isEmpty == false {
                Text(tablesErrorMessage)
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
            }
        }
    }

    private var displayText: String {
        if let errorMessage, errorMessage.isEmpty == false {
            return "Error while executing SQL:\n\n" + errorMessage
        }

        if outputText.isEmpty {
            return "Paste SQL or sqlite3 commands below, then tap Run to execute against the bundled dictionary.sqlite3 database.\n\nExamples:\n  .tables\n  SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name;"
        }

        return outputText
    }

    private func runCurrentSQL() async {
        let trimmed = sqlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }

        isRunning = true
        errorMessage = nil
        do {
            let result = try await SQLPlaygroundExecutor.shared.execute(trimmed)
            outputText = result
        } catch {
            outputText = ""
            errorMessage = String(describing: error)
        }
        isRunning = false
    }

    @MainActor
    private func reloadTablesIfNeeded() async {
        if tableNames.isEmpty {
            await reloadTables()
        }
    }

    @MainActor
    private func reloadTables() async {
        isLoadingTables = true
        tablesErrorMessage = nil
        do {
            tableNames = try await SQLPlaygroundExecutor.shared.userTableNames()
        } catch {
            tablesErrorMessage = "Could not load tables: \(String(describing: error))"
        }
        isLoadingTables = false
    }

    @MainActor
    private func appendSelectStatement(forTableNamed tableName: String) async {
        do {
            let columns = try await SQLPlaygroundExecutor.shared.columnNames(forTableNamed: tableName)
            let statement = buildSelectStatement(table: tableName, columns: columns)
            sqlText = appendStatement(existing: sqlText, statement: statement)
            isEditorFocused = true
        } catch {
            tablesErrorMessage = "Could not load columns for '\(tableName)': \(String(describing: error))"
        }
    }

    private func buildSelectStatement(table: String, columns: [String]) -> String {
        let quotedTable = quoteIdentifier(table)
        if columns.isEmpty {
            return "select * from \(quotedTable);"
        }
        let cols = columns.map(quoteIdentifier).joined(separator: ", ")
        return "select \(cols) from \(quotedTable);"
    }

    private func quoteIdentifier(_ identifier: String) -> String {
        let escaped = identifier.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private func appendStatement(existing: String, statement: String) -> String {
        let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return statement
        }

        if trimmed.hasSuffix(";") {
            return existing + "\n" + statement
        }
        return existing + ";\n" + statement
    }

    private func formatSQLDebug(_ value: String) -> String {
        let rawLines = value.split(whereSeparator: { $0.isNewline }).map(String.init)
        let nonEmpty = rawLines.filter { $0.trimmingCharacters(in: CharacterSet.whitespaces).isEmpty == false }
        guard nonEmpty.isEmpty == false else { return value }

        let leadingSpaceCounts: [Int] = nonEmpty.map { line in
            var count = 0
            for ch in line {
                if ch == " " || ch == "\t" {
                    count += 1
                } else {
                    break
                }
            }
            return count
        }

        guard let minIndent = leadingSpaceCounts.min(), minIndent > 0 else { return value }

        let trimmedLines: [String] = rawLines.map { line in
            var remainingIndent = minIndent
            var result = ""
            var dropped = true
            for ch in line {
                if dropped, remainingIndent > 0, (ch == " " || ch == "\t") {
                    remainingIndent -= 1
                    continue
                }
                dropped = false
                result.append(ch)
            }
            return result
        }

        return trimmedLines.joined(separator: "\n")
    }
}
