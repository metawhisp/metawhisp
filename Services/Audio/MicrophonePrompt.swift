import Foundation

/// The microphone prompt a record press brings up — launch never shows it,
/// so the first press does (C4). One prompt at a time, however often the key
/// goes down before the answer. The press that asks records nothing: the
/// prompt takes the screen, and a push-to-talk key is long released when it
/// is answered; the next press records. Dictation and the onboarding practice
/// ask the same way (step-1 review #9).
@MainActor
final class MicrophonePrompt {
    private var request: Task<Void, Never>?

    func ask(_ microphone: any AudioSource, _ permission: PermissionAsk,
             answered: @escaping @MainActor (Bool) -> Void) {
        guard request == nil else { return }
        NSLog("[MicrophonePrompt] 🎤 first record press — asking for the microphone")
        request = Task { [weak self] in
            let granted = await microphone.requestPermission(permission)
            self?.request = nil
            NSLog("[MicrophonePrompt] 🎤 microphone %@", granted ? "allowed" : "refused")
            answered(granted)
        }
    }
}
