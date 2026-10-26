import AppKit
import KolomCore
import SwiftUI

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// Turns a typed sentence into Kolom's structured request with Apple's
/// on-device model (macOS 26 with Apple Intelligence). Nothing leaves the Mac,
/// and the answer is checked by resolveAsk before anything runs.
enum AskInterpreter {
    /// Why asking is unavailable, or nil when the model is ready.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
            if #available(macOS 26, *) {
                switch SystemLanguageModel.default.availability {
                case .available: return nil
                case .unavailable(.deviceNotEligible): return "This Mac does not support Apple Intelligence."
                case .unavailable(.appleIntelligenceNotEnabled):
                    return "Turn on Apple Intelligence in System Settings → Apple Intelligence & Siri."
                case .unavailable(.modelNotReady):
                    return "Apple Intelligence is still preparing its model. Try again in a few minutes."
                case .unavailable: return "Apple's on-device model is unavailable right now."
                }
            }
            return "Ask Kolom needs macOS 26 with Apple Intelligence."
        #else
            return "This build of Kolom was made without Apple's on-device model; build it with the macOS 26 SDK."
        #endif
    }

    /// Load the model while the user types, so the first answer is quick.
    static func prewarm() {
        #if canImport(FoundationModels)
            if #available(macOS 26, *), case .available = SystemLanguageModel.default.availability {
                LanguageModelSession().prewarm()
            }
        #endif
    }

    static func instructions(screens: [String], pointer: Int) -> String {
        let list = screens.enumerated().map { "\($0.offset + 1) = \($0.element)" }.joined(separator: "; ")
        return """
            You turn one request for Kolom, a macOS window manager, into exactly one command.
            Actions:
            grid: open a grid of new Terminal windows. Set columns and rows. "3x2" means 3 columns and 2 rows; \
            "six terminals, three across" means 3 columns and 2 rows; "4 terminals" means 2 columns and 2 rows. \
            When the request gives a total number of windows, set count to exactly that number, even if it is large.
            desktop: scroll to the desktop.
            nextColumn: scroll forward one column. previousColumn: scroll back one column ("back", "previous", "left").
            focusApp: bring an app's window into view; set app to the app name.
            moveWindow: move the focused window to another screen; set display.
            theme: set theme to Light, Dark or Wallpaper.
            undoGrid: remove the last grid. pause: pause Kolom and put every window back.
            guide: open Kolom's guide, also for help or how-to questions. performance: open the performance dashboard.
            unknown: anything else.
            Screens, numbered left to right: \(list). The pointer is on screen \(pointer).
            Set display only when the request names or describes a screen, such as "screen 2", \
            "the left monitor" or "my main display".
            """
    }

    static func interpret(_ text: String, screens: [String], pointer: Int) async throws -> [String: Any] {
        #if canImport(FoundationModels)
            if #available(macOS 26, *) {
                // Spelled out without the @Generable macro so command-line builds work.
                let command = DynamicGenerationSchema(
                    name: "KolomCommand",
                    properties: [
                        .init(name: "action", schema: DynamicGenerationSchema(type: String.self, guides: [.anyOf(askActions)])),
                        .init(name: "columns", schema: DynamicGenerationSchema(type: Int.self), isOptional: true),
                        .init(name: "rows", schema: DynamicGenerationSchema(type: Int.self), isOptional: true),
                        .init(name: "count", schema: DynamicGenerationSchema(type: Int.self), isOptional: true),
                        .init(name: "display", schema: DynamicGenerationSchema(type: Int.self), isOptional: true),
                        .init(name: "app", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
                        .init(
                            name: "theme", schema: DynamicGenerationSchema(type: String.self, guides: [.anyOf(askThemes)]),
                            isOptional: true),
                    ])
                let schema = try GenerationSchema(root: command, dependencies: [])
                let session = LanguageModelSession(instructions: instructions(screens: screens, pointer: pointer))
                let response = try await session.respond(to: text, schema: schema)
                let data = Data(response.content.jsonString.utf8)
                return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            }
        #endif
        return [:]
    }
}

/// State of one Ask Kolom panel.
final class AskModel: ObservableObject {
    enum Phase: Equatable {
        case idle, thinking
        case working(String)
        case done(String)
        case info(String)
    }
    @Published var text = ""
    @Published var phase = Phase.idle
    let screens: [String]
    let screenNames: [String]
    let pointer: Int
    let unavailable = AskInterpreter.unavailableReason
    /// Runs a checked action and calls back with whether it worked and what
    /// happened; grids call back once their windows are verified.
    var perform: (AskAction, @escaping (Bool, String) -> Void) -> Void = { _, done in done(false, "") }
    /// Removes the panel; `ran` is true when an action completed.
    var onClose: (_ ran: Bool) -> Void = { _ in }
    private var task: Task<Void, Never>?
    private var closed = false
    init(screens: [String], screenNames: [String], pointer: Int) {
        self.screens = screens
        self.screenNames = screenNames
        self.pointer = pointer
    }
    var busy: Bool {
        if case .working = phase { return true }
        return phase == .thinking
    }
    func submit() {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !busy, unavailable == nil else { return }
        phase = .thinking
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let fields = try await AskInterpreter.interpret(request, screens: self.screenNames, pointer: self.pointer)
                // Escape while the model was thinking cancels the request: nothing runs.
                guard !Task.isCancelled, !self.closed else { return }
                switch resolveAsk(fields, text: request, displays: self.screens.count, pointerDisplay: self.pointer) {
                case .explain(let message): self.phase = .info(message)
                case .run(let action):
                    self.phase = .working(Self.describe(action))
                    self.perform(action) { [weak self] ok, message in
                        guard let self, !self.closed else { return }
                        self.phase = ok ? .done(message) : .info(message)
                        if ok {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                                if self?.phase == .done(message) { self?.dismiss(ran: true) }
                            }
                        }
                    }
                }
            } catch {
                guard !self.closed else { return }
                self.phase = .info("The on-device model could not answer: \(error.localizedDescription)")
            }
        }
    }
    func dismiss(ran: Bool = false) {
        guard !closed else { return }
        closed = true
        task?.cancel()
        onClose(ran)
    }
    static func describe(_ action: AskAction) -> String {
        switch action {
        case .grid(let columns, let rows, _): "Opening a \(columns)×\(rows) Terminal grid…"
        case .undoGrid: "Undoing the last grid…"
        default: "Working…"
        }
    }
}

struct AskView: View {
    @ObservedObject var ask: AskModel
    @KolomPreference("kolomTheme") private var theme = "Light"
    @FocusState private var typing: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles").font(.system(size: 18)).foregroundStyle(.tint)
                TextField("Ask Kolom…", text: $ask.text).textFieldStyle(.plain).font(.system(size: 20))
                    .focused($typing).onSubmit(ask.submit).disabled(ask.unavailable != nil || ask.busy)
                if ask.busy { ProgressView().controlSize(.small) }
                Button("Esc") { ask.dismiss() }.buttonStyle(.plain).foregroundColor(.secondary)
            }
            .padding(20)
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    ForEach(Array(ask.screenNames.enumerated()), id: \.offset) { index, name in
                        Text("\(index + 1) · \(name)")
                            .font(.system(size: 11, weight: index + 1 == ask.pointer ? .semibold : .regular))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(
                                Capsule().fill(
                                    index + 1 == ask.pointer ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06)))
                    }
                }
                result
            }
            .padding(20)
            Spacer(minLength: 0)
            Divider()
            Text(
                ask.unavailable == nil
                    ? "Understood by Apple's on-device model · nothing leaves this Mac · ⌥K" : "Ask Kolom is unavailable"
            )
            .font(.system(size: 10)).foregroundColor(.secondary).padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 600, height: 330)
        .background(KolomSurface(theme: theme == "Wallpaper" ? "Dark" : theme)).foregroundColor(.primary)
        .preferredColorScheme(theme == "Light" ? .light : .dark)
        .onAppear { typing = true }
        .onExitCommand { ask.dismiss() }
    }
    @ViewBuilder var result: some View {
        if let reason = ask.unavailable {
            Label(reason, systemImage: "exclamationmark.triangle").font(.system(size: 13))
        } else {
            switch ask.phase {
            case .working(let message):
                Label(message, systemImage: "hourglass").font(.system(size: 14))
            case .idle, .thinking:
                VStack(alignment: .leading, spacing: 6) {
                    Text(ask.phase == .thinking ? "Thinking on this Mac…" : "Try")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                    ForEach(askExamples, id: \.self) { example in
                        Button {
                            ask.text = example
                            ask.submit()
                        } label: {
                            Text(example).font(.system(size: 13))
                        }
                        .buttonStyle(.plain).disabled(ask.busy)
                    }
                }
            case .done(let message):
                Label(message, systemImage: "checkmark.circle.fill").foregroundColor(.green).font(.system(size: 14))
            case .info(let message):
                Label(message, systemImage: "info.circle").font(.system(size: 14))
            }
        }
    }
}
