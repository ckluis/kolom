import CoreGraphics
import Foundation

/// What a typed request ("3×2 terminals on screen 2") asks Kolom to do, once
/// the on-device model's answer has been checked. Displays are numbered from 1.
public enum AskAction: Equatable {
    case grid(columns: Int, rows: Int, display: Int)
    case desktop(display: Int)
    case column(next: Bool, display: Int)
    case focus(app: String)
    case move(display: Int)
    case theme(String)
    case undoGrid, pause, guide, performance
}

public enum AskOutcome: Equatable {
    case run(AskAction)
    case explain(String)
}

/// The actions the model may choose, in the order its instructions list them.
public let askActions = [
    "grid", "desktop", "nextColumn", "previousColumn", "focusApp", "moveWindow", "theme", "undoGrid", "pause",
    "guide", "performance", "unknown",
]
public let askThemes = ["Light", "Dark", "Wallpaper"]
public let askExamples = [
    "3×2 terminals on screen 2", "show the desktop", "focus Safari", "move this window to screen 1",
    "dark theme", "undo that grid",
]

/// Check the model's structured answer. Never trust it: unknown actions, missing
/// sizes and screens that do not exist become an explanation, not a guess.
/// `text` is what the user typed; a size written in it ("4x3") wins over the model.
public func resolveAsk(_ fields: [String: Any], text: String = "", displays: Int, pointerDisplay: Int) -> AskOutcome {
    let action = fields["action"] as? String ?? "unknown"
    let named = fields["display"] as? Int
    if let named, !(1...max(1, displays)).contains(named) {
        return .explain("There is no screen \(named); this Mac has \(displays).")
    }
    let display = named ?? pointerDisplay
    switch action {
    case "grid":
        // A small model can reshape numbers. A written size is read from the text;
        // a bare total ("8 terminals") gets the most balanced grid of exactly that many.
        var size = writtenGridSize(text)
        if size == nil, let count = fields["count"] as? Int {
            guard count <= 60 else { return .explain("A grid can have at most 60 windows.") }
            if let columns = fields["columns"] as? Int, let rows = fields["rows"] as? Int, columns * rows == count {
                size = (columns, rows)
            } else if count > 0 {
                size = balancedGrid(count)
            }
        }
        if size == nil, let columns = fields["columns"] as? Int, let rows = fields["rows"] as? Int {
            size = (columns, rows)
        }
        guard let (columns, rows) = size else {
            return .explain("Say how many columns and rows, like “3×2 terminals”.")
        }
        guard (1...30).contains(columns), (1...30).contains(rows), columns * rows <= 60 else {
            return .explain("A grid can have at most 60 windows.")
        }
        return .run(.grid(columns: columns, rows: rows, display: display))
    case "desktop": return .run(.desktop(display: display))
    case "nextColumn", "previousColumn": return .run(.column(next: action == "nextColumn", display: display))
    case "focusApp":
        let app = (fields["app"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return app.isEmpty ? .explain("Which app should I focus?") : .run(.focus(app: app))
    case "moveWindow":
        guard named != nil else { return .explain("Which screen should the window move to?") }
        return .run(.move(display: display))
    case "theme":
        guard let theme = askThemes.first(where: { $0.lowercased() == (fields["theme"] as? String)?.lowercased() })
        else { return .explain("Kolom has Light, Dark and Wallpaper themes.") }
        return .run(.theme(theme))
    case "undoGrid": return .run(.undoGrid)
    case "pause": return .run(.pause)
    case "guide": return .run(.guide)
    case "performance": return .run(.performance)
    default:
        return .explain("I can make Terminal grids, scroll, focus apps, move windows and change the theme. Try “3×2 terminals on screen 2”.")
    }
}

/// "4x3", "4 × 3" or "4 by 3" in the text: columns first, as people say grid sizes.
public func writtenGridSize(_ text: String) -> (columns: Int, rows: Int)? {
    guard
        let match = text.range(of: #"(\d+)\s*(x|×|by|\*)\s*(\d+)"#, options: [.regularExpression, .caseInsensitive])
    else { return nil }
    let numbers = text[match].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    return numbers.count == 2 ? (numbers[0], numbers[1]) : nil
}

/// Exactly `count` cells, as square as possible, wider than tall.
public func balancedGrid(_ count: Int) -> (columns: Int, rows: Int) {
    var rows = Int(Double(count).squareRoot())
    while rows > 1, count % rows != 0 { rows -= 1 }
    return (count / max(rows, 1), max(rows, 1))
}

/// Screens are numbered left to right as they stand on the desk, then top to
/// bottom, which is how people count them.
public func askDisplayOrder(_ desk: [(id: String, frame: CGRect)]) -> [String] {
    desk.sorted { ($0.frame.minX, $0.frame.minY, $0.id) < ($1.frame.minX, $1.frame.minY, $1.id) }.map(\.id)
}
