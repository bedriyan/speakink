import Foundation

/// Abstraction over clipboard paste operations for testability.
protocol Pasting: AnyObject {
    func paste(_ text: String)
}

extension PasteService: Pasting {}
