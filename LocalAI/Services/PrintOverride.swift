import Foundation

/// Overrides the global `print` function for the entire module to ensure that
/// debug statements are not accidentally leaked into the production console.
func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    #if DEBUG
    var result = ""
    for (index, item) in items.enumerated() {
        result.append(String(describing: item))
        if index < items.count - 1 {
            result.append(separator)
        }
    }
    result.append(terminator)
    Swift.print(result, terminator: "")
    #endif
}
