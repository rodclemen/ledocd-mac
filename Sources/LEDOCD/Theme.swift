import SwiftUI

/// Single source of truth for every color the app uses deliberately, so the
/// same meaning is always the same color (one green, one red, one yellow…).
/// The system accent color is never used for status: on a Mac whose accent is
/// set to green or red it would collide with these and lie about state.
enum Theme {
    /// Good / on / connected: Connect once a board answered, Send while there
    /// are unsent changes, Live Mode & Manual Test while active, and the
    /// board-registered matrix pill.
    static let good = Color.green

    /// Needs attention / pending: Save‑Commit while unstored, the wrong-matrix
    /// pill, the SIMULATED badge, and the active-mode overlay label.
    static let alert = Color.red

    /// A lit lamp: preview bulbs and the shown-profile highlight in the tables.
    static let lamp = Color.yellow

    /// An enabled (but not registered, not wrong) matrix pill.
    static let amber = Color(red: 0.78, green: 0.60, blue: 0.16)

    /// A disabled matrix pill's fill.
    static let pillOff = Color(white: 0.40)

    /// Subtle darkening: the editor background and striped table rows.
    static let shade = Color.black.opacity(0.06)

    /// The dimmed bold "Detected:" label in the header.
    static let headerDim = Color(white: 0.80)
}
