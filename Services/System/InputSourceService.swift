import Carbon
import Foundation

/// Identifies the two input sources that v1 supports. Exact identifiers keep
/// us from silently applying a US mapping to a different English layout.
enum InputSourceIDResolver {
    static let englishUS = "com.apple.keylayout.US"
    static let russian = "com.apple.keylayout.Russian"

    static func layout(for identifier: String) -> KeyboardLayout? {
        switch identifier {
        case englishUS: .englishUS
        case russian: .russian
        default: nil
        }
    }
}

/// Reads and selects only the verified US/Russian macOS input sources.
///
/// No user text passes through this service; it deals solely in source IDs.
@MainActor
final class InputSourceService {
    func currentLayout() -> KeyboardLayout? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let identifier = stringProperty(kTISPropertyInputSourceID, from: source) else {
            return nil
        }
        return InputSourceIDResolver.layout(for: identifier)
    }

    @discardableResult
    func select(_ layout: KeyboardLayout) -> Bool {
        guard let source = configuredSource(for: layout) else { return false }
        return TISSelectInputSource(source) == noErr
    }

    private func configuredSource(for layout: KeyboardLayout) -> TISInputSource? {
        let properties = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource
        ] as CFDictionary
        let sources = TISCreateInputSourceList(properties, false)
            .takeRetainedValue() as! [TISInputSource]

        return sources.first {
            guard let identifier = stringProperty(kTISPropertyInputSourceID, from: $0) else {
                return false
            }
            return InputSourceIDResolver.layout(for: identifier) == layout
        }
    }

    private func stringProperty(_ property: CFString, from source: TISInputSource) -> String? {
        guard let value = TISGetInputSourceProperty(source, property) else { return nil }
        return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
    }
}
