import SwiftUI

public struct IoTTheme: Sendable {
    public var tint: Color
    public var cornerRadius: CGFloat
    public init(tint: Color = .teal, cornerRadius: CGFloat = 20) {
        self.tint = tint; self.cornerRadius = max(0, cornerRadius)
    }
}
private struct IoTThemeKey: EnvironmentKey { static let defaultValue = IoTTheme() }
public extension EnvironmentValues {
    var iotTheme: IoTTheme {
        get { self[IoTThemeKey.self] }
        set { self[IoTThemeKey.self] = newValue }
    }
}
public extension View {
    func iotTheme(_ theme: IoTTheme) -> some View { environment(\.iotTheme, theme).tint(theme.tint) }
}
func iotText(_ key: String) -> Text { Text(LocalizedStringKey(key), bundle: .module) }
func iotString(_ key: String, locale: Locale) -> String {
    let language = locale.language.languageCode?.identifier ?? "en"
    let localizedBundle = Bundle.module.path(forResource: language, ofType: "lproj")
        .flatMap(Bundle.init(path:)) ?? .module
    return localizedBundle.localizedString(forKey: key, value: nil, table: nil)
}
