import SwiftUI
import UniformTypeIdentifiers

#if !os(tvOS)

/// A module's script, to read and change in the app.
///
/// Nothing is kept until Save. The text can also be swapped whole for the clipboard's or a .js
/// file's, after a warning, which is how a fixed script from elsewhere goes in.
struct ModuleScriptEditorView: View {
    let moduleID: String
    @EnvironmentObject private var moduleManager: ModuleManager
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var saved = ""
    @State private var loaded = false
    @State private var confirmPaste = false
    @State private var confirmImport = false
    @State private var showImporter = false
    @State private var confirmDiscard = false
    @State private var confirmRevert = false
    @State private var isReverting = false
    @State private var syntaxError: String?
    @State private var problem: String?

    private var module: ModuleDefinition? { moduleManager.modules.first { $0.id == moduleID } }
    private var isDirty: Bool { loaded && text != saved }

    var body: some View {
        VStack(spacing: 0) {
            if let module, module.isScriptEdited {
                editedBanner
            }
            CodeTextEditor(text: $text)
            footer
        }
        .navigationTitle(module?.sourceName ?? String(localized: "modules.script"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(isDirty)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("common.cancel") {
                    if isDirty { confirmDiscard = true } else { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("common.save", action: save)
                    .disabled(!isDirty)
            }
            ToolbarItem(placement: .automatic) {
                Menu {
                    Button(role: .destructive) {
                        confirmPaste = true
                    } label: {
                        Label("modules.replace_all_with_clipboard", icon: "doc.on.clipboard")
                    }
                    Button {
                        confirmImport = true
                    } label: {
                        Label("modules.replace_with_a_js_file", icon: "doc.badge.arrow.up")
                    }
                    Divider()
                    Button {
                        Clipboard.copy(text)
                    } label: {
                        Label("modules.copy_all", icon: "doc.on.doc")
                    }
                    if #available(iOS 16.0, macOS 13.0, *) {
                        ShareLink(item: text) {
                            Label("modules.share_script", icon: "square.and.arrow.up")
                        }
                    }
                    if let module, module.isScriptEdited {
                        Divider()
                        Button(role: .destructive) {
                            confirmRevert = true
                        } label: {
                            Label("modules.revert_to_original", icon: "arrow.uturn.backward")
                        }
                    }
                } label: {
                    IconView("ellipsis.circle")
                }
            }
        }
        .onAppear {
            guard !loaded else { return }
            text = module?.scriptContent ?? ""
            saved = text
            loaded = true
        }
        .confirmationDialog("modules.replace_the_whole_script", isPresented: $confirmPaste, titleVisibility: .visible) {
            Button("modules.delete_all_and_paste", role: .destructive, action: pasteClipboard)
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("modules.paste_replaces_editor_detail")
        }
        .confirmationDialog("modules.replace_the_whole_script", isPresented: $confirmImport, titleVisibility: .visible) {
            Button("modules.choose_a_js_file", role: .destructive) { showImporter = true }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("modules.file_replaces_editor")
        }
        .confirmationDialog("modules.discard_your_changes", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("modules.discard_changes", role: .destructive) { dismiss() }
            Button("modules.keep_editing", role: .cancel) {}
        }
        .confirmationDialog("modules.revert_to_the_original_script", isPresented: $confirmRevert, titleVisibility: .visible) {
            Button("modules.revert", role: .destructive, action: revert)
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("modules.your_edits_are_thrown_away")
        }
        .alert("modules.the_script_has_a_syntax", isPresented: Binding(
            get: { syntaxError != nil }, set: { if !$0 { syntaxError = nil } }
        )) {
            Button("modules.save_anyway", role: .destructive) { commit() }
            Button("modules.keep_editing", role: .cancel) {}
        } message: {
            Text(verbatim: (syntaxError.map { $0 + "\n\n" } ?? "") + String(localized: "modules.saved_like_this_the_module"))
        }
        .alert("modules.couldnt_do_that", isPresented: Binding(
            get: { problem != nil }, set: { if !$0 { problem = nil } }
        )) {
            Button("common.ok", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.javaScript, .plainText]) { result in
            switch result {
            case .success(let url): importScript(from: url)
            case .failure(let error): problem = error.localizedDescription
            }
        }
    }

    private var editedBanner: some View {
        HStack(spacing: 8) {
            IconView("pencil.circle.fill")
            Text("modules.edited_in_shirox_updates_skip")
                .font(.caption)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    private var footer: some View {
        HStack {
            Text("modules.lines \(lineCount) \(ByteCountFormatter.string(fromByteCount: Int64(text.utf8.count), countStyle: .file))")
            Spacer()
            if isReverting {
                ProgressView().scaleEffect(0.7)
            } else if isDirty {
                Text("modules.unsaved_changes")
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    private var lineCount: Int {
        text.isEmpty ? 0 : text.reduce(into: 1) { if $1 == "\n" { $0 += 1 } }
    }

    private func pasteClipboard() {
        guard let pasted = Clipboard.string, !pasted.isEmpty else {
            problem = String(localized: "modules.theres_no_text_on_the")
            return
        }
        text = pasted
    }

    private func importScript(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let script = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            problem = "\(url.lastPathComponent) couldn't be read as text."
            return
        }
        text = script
    }

    private func save() {
        if let error = ModuleFileImport.syntaxError(in: text) {
            syntaxError = error
        } else {
            commit()
        }
    }

    private func commit() {
        moduleManager.saveScript(text, for: moduleID)
        saved = text
        #if os(iOS)
        ToastManager.shared.show(message: String(localized: "modules.script_saved"), type: .info)
        #endif
        dismiss()
    }

    private func revert() {
        isReverting = true
        Task {
            let ok = await moduleManager.revertScript(for: moduleID)
            isReverting = false
            if ok {
                text = module?.scriptContent ?? ""
                saved = text
            } else {
                problem = String(localized: "modules.the_original_script_couldnt_be")
            }
        }
    }
}

// MARK: - Code text view

/// Plain monospaced text with every typing aid off: smart quotes and dashes would turn `"` and
/// `--` into characters JavaScript can't read. Coloured as VS Code colours JavaScript, a moment
/// after typing stops.
#if os(iOS)
struct CodeTextEditor: UIViewRepresentable {
    @Binding var text: String

    static let font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = Self.font
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.keyboardType = .asciiCapable
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        view.backgroundColor = .systemBackground
        view.delegate = context.coordinator
        view.text = text
        context.coordinator.highlight(view)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text {
            view.text = text
            context.coordinator.highlight(view)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        private var pending: DispatchWorkItem?
        init(text: Binding<String>) { self.text = text }

        func textViewDidChange(_ view: UITextView) {
            text.wrappedValue = view.text
            view.typingAttributes = [.font: CodeTextEditor.font, .foregroundColor: UIColor.label]
            pending?.cancel()
            let work = DispatchWorkItem { [weak self, weak view] in
                guard let self, let view else { return }
                self.highlight(view)
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }

        func highlight(_ view: UITextView) {
            JavaScriptHighlighter.apply(to: view.textStorage, font: CodeTextEditor.font)
            view.typingAttributes = [.font: CodeTextEditor.font, .foregroundColor: UIColor.label]
        }
    }
}
#elseif os(macOS)
struct CodeTextEditor: NSViewRepresentable {
    @Binding var text: String

    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.font = Self.font
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.isRichText = false
        view.allowsUndo = true
        view.textContainerInset = NSSize(width: 6, height: 10)
        view.delegate = context.coordinator
        view.string = text
        context.coordinator.highlight(view)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text {
            view.string = text
            context.coordinator.highlight(view)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        private var pending: DispatchWorkItem?
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ note: Notification) {
            guard let view = note.object as? NSTextView else { return }
            text.wrappedValue = view.string
            pending?.cancel()
            let work = DispatchWorkItem { [weak self, weak view] in
                guard let self, let view else { return }
                self.highlight(view)
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }

        func highlight(_ view: NSTextView) {
            guard let storage = view.textStorage else { return }
            JavaScriptHighlighter.apply(to: storage, font: CodeTextEditor.font)
            view.typingAttributes = [.font: CodeTextEditor.font, .foregroundColor: NSColor.textColor]
        }
    }
}
#endif
#endif
