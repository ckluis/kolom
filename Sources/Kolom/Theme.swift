import SwiftUI
import AppKit

typealias KolomPreference<Value> = SwiftUI.AppStorage<Value> where Value: Equatable
// Spelled as a type so the build does not need the SwiftUI macro plugin.
typealias KolomState<Value> = SwiftUI.State<Value>
struct KolomSurface: View {
    let theme: String
    var body: some View {
        ZStack {
            if theme == "Wallpaper" {
                Color.clear
            } else {
                theme == "Light" ? Color(red: 0.95, green: 0.96, blue: 0.92) : Color(red: 0.10, green: 0.14, blue: 0.12)
            }
        }
    }
}
