import SwiftUI
import UIKit

struct PreferredLanguageTextField: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let preferredLanguagePrefixes: [String]
    let autocorrectionDisabled: Bool
    let autocapitalization: UITextAutocapitalizationType

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> SharedPreferredLanguageUITextField {
        let textField = SharedPreferredLanguageUITextField(frame: .zero)
        textField.delegate = context.coordinator
        textField.placeholder = placeholder
        textField.text = text
        textField.preferredLanguagePrefixes = preferredLanguagePrefixes
        textField.autocorrectionType = autocorrectionDisabled ? .no : .yes
        textField.autocapitalizationType = autocapitalization
        textField.spellCheckingType = autocorrectionDisabled ? .no : .default
        textField.smartDashesType = .no
        textField.smartQuotesType = .no
        textField.smartInsertDeleteType = .no
        textField.returnKeyType = .done
        textField.enablesReturnKeyAutomatically = false
        textField.clearButtonMode = .whileEditing
        textField.borderStyle = .none
        textField.backgroundColor = .clear
        textField.textColor = .label
        textField.font = UIFont.preferredFont(forTextStyle: .body)
        textField.adjustsFontForContentSizeCategory = true
        textField.addTarget(context.coordinator, action: #selector(Coordinator.textDidChange(_:)), for: .editingChanged)
        return textField
    }

    func updateUIView(_ uiView: SharedPreferredLanguageUITextField, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
        uiView.placeholder = placeholder
        uiView.preferredLanguagePrefixes = preferredLanguagePrefixes
        uiView.autocorrectionType = autocorrectionDisabled ? .no : .yes
        uiView.autocapitalizationType = autocapitalization
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        private var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        @objc func textDidChange(_ sender: UITextField) {
            text.wrappedValue = sender.text ?? ""
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            return false
        }
    }
}

final class SharedPreferredLanguageUITextField: UITextField {
    var preferredLanguagePrefixes: [String] = []

    override var textInputMode: UITextInputMode? {
        guard preferredLanguagePrefixes.isEmpty == false else {
            return super.textInputMode
        }

        for mode in UITextInputMode.activeInputModes {
            guard let primary = mode.primaryLanguage else { continue }
            if preferredLanguagePrefixes.contains(where: { primary.hasPrefix($0) }) {
                return mode
            }
        }

        return super.textInputMode
    }
}
