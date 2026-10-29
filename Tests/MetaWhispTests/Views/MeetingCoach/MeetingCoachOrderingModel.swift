import AppKit
@testable import MetaWhisp

/// Executes the production ordering branches without ordering any native window.
/// AppKit can detach a child on orderOut; this model makes every such loss explicit.
@MainActor
final class MeetingCoachOrderingModel {
    private(set) var panels: [ObjectIdentifier: Panel] = [:]

    func adapter(_ panel: NSPanel) -> Panel {
        let key = ObjectIdentifier(panel)
        if let existing = panels[key] { return existing }
        let result = Panel(panel)
        panels[key] = result
        return result
    }

    final class Panel: MeetingCoachPanelOrdering {
        let panel: NSPanel
        var calls: [String] = []
        private(set) var visible = false

        init(_ panel: NSPanel) { self.panel = panel }

        func endEditing(for object: Any?) {
            calls.append("endEditing")
        }

        func orderOut(_ sender: Any?) {
            calls.append("orderOut")
            visible = false
            panel.parent?.removeChildWindow(panel)
            for child in panel.childWindows ?? [] { panel.removeChildWindow(child) }
        }

        func orderFrontRegardless() {
            calls.append("orderFrontRegardless")
            visible = true
        }
    }
}
