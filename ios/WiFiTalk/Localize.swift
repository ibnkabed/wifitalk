import Foundation

/// The interface follows the phone's language. The Arabic text in the code is the key, and
/// `en.lproj/Localizable.strings` holds its English; an Arabic phone shows the key itself.
func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

/// The same with `%@` arguments, in order.
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), arguments: args)
}

enum Lang {
    /// True when the interface is Arabic.
    static let isArabic: Bool = (Bundle.main.preferredLocalizations.first ?? "ar").hasPrefix("ar")
}