import Combine
import Foundation

/// Presentation belongs to the controller, independently of answer eligibility.
@MainActor
final class MeetingCoachPresentation: ObservableObject {
    @Published var isExpanded = false
}
