import Foundation

/// What a screen observation is allowed to do to the user's task list.
///
/// The answer is: nothing, until there is somewhere for a proposal to go.
///
/// Measured on the real store on 2026-08-29, before this switch existed:
/// 957 screen-derived tasks sat in `staged`, invisible, the oldest from 21
/// April; exactly 5 had ever reached a status the user could see. The promotion
/// loop only advances when a slot frees — when the user completes or dismisses
/// something — and with 481 open tasks a slot never frees. So one half of this
/// feature had been filling a queue nobody could read for four months.
///
/// The other half worked, and that was worse. A phrase on screen — someone
/// else's message, a quote of an old one — was enough to mark a task the user
/// had written themselves as done. No confirmation, no receipt, no undo; the
/// first they learned of it was the task missing.
///
/// The reference implementation models this as a candidate with a
/// `proposed_action`, resolved only by an explicit accept or reject that
/// returns a receipt, and expiring on its own if nobody answers. Until that
/// surface exists here, the honest position is that the model may notice and
/// may not act. The noticing is deliberately left running: gating the
/// observation instead of the mutation would throw away the signal the
/// confirmation flow will need.
enum ScreenDerivedTaskPolicy {

    /// Screen text may propose; only the user may decide.
    ///
    /// Flip this to `true` only together with a surface that shows the
    /// proposal, takes an answer, writes a receipt and can be undone. Flipping
    /// it alone restores silent mutation of the user's own work.
    static let mayMutateWithoutConfirmation = false
}
