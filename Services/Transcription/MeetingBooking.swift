import Foundation

/// What a meeting books of the Pro quota (ITER-054): its wall-clock length, once for both channels — in the share of
/// it the Pro proxy transcribed, which is this booking's only charge (every chunk went out count_usage=false).
///
/// The engine can change from chunk to chunk while a meeting is transcribed (A4: Pro ending or coming back, the
/// engine chosen in Settings), so each chunk counts by the engine that actually transcribed it — never the engine the
/// meeting began on. A meeting wholly through the proxy books its whole length, as before; one wholly on this Mac or
/// on the user's own key books nothing; one that moved between them books the proxy's part. A chunk no engine
/// transcribed — all its attempts failed — books nothing, as a replay books nothing (`MeetingChunkRetryPolicy`).
struct MeetingBooking: Equatable {
    /// Seconds of the chunks that went to an engine, transcribed or failed — each chunk's length on the meeting's
    /// timeline. A chunk too quiet to send counts in neither sum.
    private(set) var chunkSeconds: Double = 0
    /// Of those, the seconds the Pro proxy transcribed.
    private(set) var proxySeconds: Double = 0

    /// A chunk `seconds` long that went to an engine: `viaProProxy` when the Pro proxy transcribed it — false when
    /// another engine did, or none did.
    mutating func add(seconds: Double, viaProProxy: Bool) {
        chunkSeconds += seconds
        if viaProProxy { proxySeconds += seconds }
    }

    /// One booking for the meeting's two channels.
    static func + (a: MeetingBooking, b: MeetingBooking) -> MeetingBooking {
        var both = a
        both.chunkSeconds += b.chunkSeconds
        both.proxySeconds += b.proxySeconds
        return both
    }

    /// The minutes a meeting `duration` seconds long books: none when the proxy transcribed none of it.
    func minutes(forMeetingOf duration: TimeInterval) -> Double {
        guard proxySeconds > 0 else { return 0 }
        return duration / 60 * (proxySeconds / chunkSeconds)
    }
}
