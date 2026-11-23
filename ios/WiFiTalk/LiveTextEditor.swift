import SwiftUI
import UIKit

private final class BackspaceTextView: UITextView {
    var onEmptyBackspace: (() -> Void)?

    override func deleteBackward() {
        if text.isEmpty {
            onEmptyBackspace?()
        }
        super.deleteBackward()
    }
}

struct LiveTextEditor: UIViewRepresentable {
    @Binding var text: String
    let onEdit: (String, String) -> Void
    let onEmptyBackspace: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextView {
        let view = BackspaceTextView()
        view.delegate = context.coordinator
        view.onEmptyBackspace = onEmptyBackspace
        view.backgroundColor = .clear
        view.textColor = UIColor(red: 0.82, green: 0.87, blue: 0.93, alpha: 1)
        view.tintColor = .systemCyan
        view.font = .preferredFont(forTextStyle: .body)
        view.textAlignment = .natural
        view.keyboardDismissMode = .none
        view.autocorrectionType = .yes
        view.smartDashesType = .yes
        view.smartQuotesType = .yes
        view.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 42, right: 10)
        view.text = text
        context.coordinator.lastValue = text
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self
        (uiView as? BackspaceTextView)?.onEmptyBackspace = onEmptyBackspace
        guard uiView.text != text else { return }
        uiView.text = text
        context.coordinator.lastValue = text
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: LiveTextEditor
        var lastValue = ""

        init(_ parent: LiveTextEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            let newValue = textView.text ?? ""
            let oldValue = lastValue
            lastValue = newValue
            parent.text = newValue
            parent.onEdit(oldValue, newValue)
        }
    }
}
