import SwiftUI
import UIKit

/// Off-by-default switch for Trilium `eraseNotes` (skip Trash). Used in the bulk-delete sheet.
struct PermanentlyDeleteNotesToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle(
            String(localized: "Delete permanently", comment: "Note delete: erase instead of moving to Trash"),
            isOn: $isOn
        )
    }
}

enum NoteDeleteConfirmationCopy {
    static func eraseFooter(erasePermanently: Bool) -> String {
        if erasePermanently {
            return String(
                localized: "Notes will not go to Trash and cannot be restored.",
                comment: "Note delete confirmation when permanent erase is on"
            )
        }
        return String(
            localized: "Deleted notes go to Trash and can be restored in Trilium.",
            comment: "Note delete confirmation when permanent erase is off"
        )
    }

    static func singleNoteMessage(title: String) -> String {
        String(
            localized: "This will delete “\(title)” and all its subnotes.",
            comment: "Note delete alert message"
        )
    }

    static func bulkMessage(count: Int) -> String {
        String(
            localized: "Delete \(count) note(s) and all of their subnotes?",
            comment: "Bulk note delete alert message"
        )
    }

    static func bulkListHeader(erasePermanently: Bool) -> String {
        if erasePermanently {
            return String(
                localized: "The following notes and their subnotes will be permanently erased. This cannot be undone.",
                comment: "Tree bulk delete sheet header when erase is on"
            )
        }
        return String(
            localized: "The following notes and their subnotes will be deleted.",
            comment: "Tree bulk delete sheet header when erase is off"
        )
    }
}

extension View {
    /// System confirm popup (`UIAlertController`) with an off-by-default toggle between the message and buttons:
    /// permanent erase unless `toggleTitle` names another choice.
    func noteDeleteConfirmationAlert(
        isPresented: Binding<Bool>,
        title: String,
        message: String,
        confirmTitle: String = String(localized: "Delete", comment: "Confirm delete"),
        toggleTitle: String = String(
            localized: "Delete permanently",
            comment: "Note delete: erase instead of moving to Trash"
        ),
        erasePermanently: Binding<Bool>,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void = {}
    ) -> some View {
        background {
            NoteDeleteConfirmationAlertPresenter(
                isPresented: isPresented,
                title: title,
                message: message,
                confirmTitle: confirmTitle,
                toggleTitle: toggleTitle,
                erasePermanently: erasePermanently,
                onConfirm: onConfirm,
                onCancel: onCancel
            )
            .frame(width: 1, height: 1)
            .accessibilityHidden(true)
        }
    }
}

/// Presents a system alert with a UISwitch in the text-field slot (between message and actions).
private struct NoteDeleteConfirmationAlertPresenter: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var title: String
    var message: String
    var confirmTitle: String
    var toggleTitle: String
    @Binding var erasePermanently: Bool
    var onConfirm: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        return controller
    }

    func updateUIViewController(_ uiViewController: Controller, context: Context) {
        context.coordinator.parent = self
        uiViewController.sync(isPresented: isPresented, coordinator: context.coordinator)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: NoteDeleteConfirmationAlertPresenter?
        var alert: UIAlertController?
        weak var toggle: UISwitch?

        @objc func toggleChanged(_ sender: UISwitch) {
            parent?.erasePermanently = sender.isOn
        }

        func textFieldShouldBeginEditing(_ textField: UITextField) -> Bool { false }
    }

    final class Controller: UIViewController {
        func sync(isPresented: Bool, coordinator: Coordinator) {
            if isPresented {
                presentIfNeeded(coordinator: coordinator)
            } else {
                dismissIfNeeded(coordinator: coordinator)
            }
        }

        private func presentIfNeeded(coordinator: Coordinator, attempt: Int = 0) {
            guard coordinator.alert == nil, coordinator.parent?.isPresented == true else { return }
            // A sheet/popover that triggered the delete may still be animating away; wait for it instead of
            // giving up (otherwise the alert only shows on some unrelated later SwiftUI update).
            if view.window == nil || presentedViewController != nil {
                guard attempt < 100 else { return }
                if let transition = presentedViewController?.transitionCoordinator {
                    transition.animate(alongsideTransition: nil) { [weak self] _ in
                        self?.presentIfNeeded(coordinator: coordinator, attempt: attempt + 1)
                    }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                        self?.presentIfNeeded(coordinator: coordinator, attempt: attempt + 1)
                    }
                }
                return
            }
            guard let parent = coordinator.parent else { return }
            let alert = Self.makeAlert(parent: parent, coordinator: coordinator)
            coordinator.alert = alert
            present(alert, animated: true)
        }

        private func dismissIfNeeded(coordinator: Coordinator) {
            guard let alert = coordinator.alert else { return }
            coordinator.alert = nil
            if presentedViewController === alert {
                alert.dismiss(animated: true)
            }
        }

        private static func makeAlert(
            parent: NoteDeleteConfirmationAlertPresenter,
            coordinator: Coordinator
        ) -> UIAlertController {
            let alert = UIAlertController(
                title: parent.title,
                message: parent.message,
                preferredStyle: .alert
            )

            alert.addTextField { textField in
                textField.delegate = coordinator
                textField.borderStyle = .none
                textField.backgroundColor = .clear
                textField.tintColor = .clear
                textField.text = nil
                textField.placeholder = nil
                textField.autocorrectionType = .no
                textField.spellCheckingType = .no

                let row = PermanentEraseToggleRow()
                row.label.text = parent.toggleTitle
                row.toggle.isOn = parent.erasePermanently
                row.toggle.addTarget(coordinator, action: #selector(Coordinator.toggleChanged(_:)), for: .valueChanged)
                coordinator.toggle = row.toggle
                row.translatesAutoresizingMaskIntoConstraints = false
                textField.addSubview(row)
                NSLayoutConstraint.activate([
                    row.leadingAnchor.constraint(equalTo: textField.leadingAnchor),
                    row.trailingAnchor.constraint(equalTo: textField.trailingAnchor),
                    row.topAnchor.constraint(equalTo: textField.topAnchor),
                    row.bottomAnchor.constraint(equalTo: textField.bottomAnchor),
                    textField.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
                ])

                DispatchQueue.main.async {
                    textField.backgroundColor = .clear
                    textField.superview?.backgroundColor = .clear
                    textField.superview?.superview?.backgroundColor = .clear
                }
            }

            alert.addAction(UIAlertAction(
                title: String(localized: "Cancel", comment: "Cancel delete"),
                style: .cancel,
                handler: { _ in
                    coordinator.alert = nil
                    coordinator.parent?.erasePermanently = false
                    coordinator.parent?.onCancel()
                    coordinator.parent?.isPresented = false
                }
            ))
            alert.addAction(UIAlertAction(
                title: parent.confirmTitle,
                style: .destructive,
                handler: { _ in
                    let erase = coordinator.toggle?.isOn ?? false
                    coordinator.alert = nil
                    coordinator.parent?.erasePermanently = erase
                    coordinator.parent?.onConfirm()
                    coordinator.parent?.isPresented = false
                }
            ))
            return alert
        }
    }
}

private final class PermanentEraseToggleRow: UIView {
    let label = UILabel()
    let toggle = UISwitch()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        backgroundColor = .clear

        label.text = String(
            localized: "Delete permanently",
            comment: "Note delete: erase instead of moving to Trash"
        )
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .label
        // The alert's text-field slot is one line high: a longer label was cut off.
        label.numberOfLines = 1
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.7
        label.adjustsFontForContentSizeCategory = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        toggle.setContentCompressionResistancePriority(.required, for: .horizontal)
        toggle.setContentHuggingPriority(.required, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [label, toggle])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }
}
