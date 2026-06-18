import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Restores punctuation and capitalization on text from ASR backends that
/// don't produce them natively. Currently used by `ParakeetBackend` because
/// the mlx-audio port of Parakeet TDT 0.6B v3 outputs lowercase text without
/// punctuation, despite NVIDIA's original model card explicitly claiming
/// PnC support — the conversion to MLX format appears to have lost the
/// punctuation/capitalization vocabulary tokens. Whisper is unaffected
/// (it produces PnC natively) and so its outputs don't route through here.
///
/// **Backend.** Apple's on-device Foundation Model (macOS 26+, requires
/// Apple Intelligence to be enabled in System Settings). 3B parameters,
/// roughly 50-200 ms per typical Parakeet segment. No additional downloads
/// or R2 mirror entries needed since the model ships with the OS. Free; no
/// API key required.
///
/// **Failure modes — all graceful.** Every failure path returns the input
/// unchanged. The contract is "improvement when available, never
/// degradation":
///   - macOS < 26 → returns input
///   - Apple Intelligence not enabled in System Settings → returns input
///   - Foundation Model still downloading post-Apple-Intelligence-enable → returns input
///   - Generation error or model busy → returns input, logs warning
///   - Restored output suspiciously different length from input
///     (model refused, hallucinated, or paraphrased) → returns input
///
/// **Why not MainActor.** Apple's `LanguageModelSession.respond` is
/// async-throwing and yields between tokens; running on a background
/// actor keeps MainActor free for SwiftUI. `@unchecked Sendable` is safe
/// here because the class has no mutable state — each `restore` call
/// builds a fresh `LanguageModelSession` (cheap once the model is
/// loaded), avoiding any need for cross-call state synchronization.
final class PnCRestorer: @unchecked Sendable {
    static let shared = PnCRestorer()

    private init() {}

    /// Per-session instructions sent to the Foundation Model. Designed to
    /// be conservative: ASR transcription is content the user wants
    /// preserved exactly, so the prompt is heavily constrained against
    /// paraphrasing, summarizing, or "improving" the text. The model only
    /// gets to change letter case and add punctuation marks.
    ///
    /// The on-device Foundation Model is a 3B-parameter instruction-
    /// following model; in practice it respects these constraints well
    /// for short conversational text. Longer multi-sentence inputs
    /// occasionally tempt it to compress filler words ("um", "uh"); the
    /// length sanity check in `restore` catches the degenerate cases.
    private static let instructions = """
    You restore punctuation and capitalization to lowercase transcribed speech.

    Rules:
    - Output ONLY the restored text. No prefix, suffix, commentary, quotes, or explanation.
    - Do NOT change wording. Do NOT add or remove words.
    - Do NOT interpret, summarize, or correct grammar.
    - Only modify letter case and add standard punctuation (periods, commas, question marks, apostrophes for contractions).
    - Preserve every word in the same order, including filler words like "uh" and "um".
    - If the input is already properly punctuated, return it unchanged.
    """

    /// Availability status for the PnC restorer. Read through to
    /// `SystemLanguageModel.default.availability` on macOS 26+,
    /// returns unavailable with a human-readable reason otherwise.
    enum AvailabilityStatus: Equatable {
        case available
        case unavailable(reason: String)

        var isAvailable: Bool {
            if case .available = self { return true }
            return false
        }
    }

    /// Current availability. Suitable for use in SwiftUI by polling on
    /// view appearance — Apple Intelligence state can change at runtime
    /// (user enables/disables it in System Settings), so this is read
    /// fresh each time rather than cached.
    var availability: AvailabilityStatus {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                switch reason {
                case .appleIntelligenceNotEnabled:
                    return .unavailable(reason: "Apple Intelligence is not enabled in System Settings → Apple Intelligence & Siri.")
                case .deviceNotEligible:
                    return .unavailable(reason: "This Mac does not support Apple Intelligence (requires Apple Silicon with at least 8 GB RAM).")
                case .modelNotReady:
                    return .unavailable(reason: "Foundation Model is still downloading. Check back in a few minutes.")
                @unknown default:
                    return .unavailable(reason: "Foundation Model is unavailable.")
                }
            }
        }
        return .unavailable(reason: "Requires macOS 26.0 (Tahoe) or later.")
        #else
        return .unavailable(reason: "FoundationModels framework not available at build time.")
        #endif
    }

    /// Restore PnC on `rawText`. Returns the input unchanged on any
    /// failure — see class doc for failure modes.
    ///
    /// Latency: typically 50-200 ms for 10-30 word segments. Scales
    /// roughly linearly with input length. Inference happens on the
    /// Neural Engine where available, so it doesn't compete with MLX
    /// model inference on the GPU.
    func restore(_ rawText: String) async -> String {
        // Cheap rejection: empty input passes through unchanged.
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rawText }

        // Cheap rejection: skip if unavailable. The availability check
        // is fast (just polls SystemLanguageModel), so doing it per-call
        // is fine even for long sessions.
        guard availability.isAvailable else { return rawText }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            do {
                // Fresh session per call. Two reasons:
                //   1. The model is already resident in memory after the
                //      first session, so creation is cheap (single-digit ms).
                //   2. Avoiding shared history between unrelated segments
                //      keeps each restoration starting from clean state —
                //      we don't want a model misstep on one segment
                //      polluting context for the next.
                let session = LanguageModelSession(instructions: Self.instructions)
                let response = try await session.respond(to: rawText)
                let restored = response.content.trimmingCharacters(in: .whitespacesAndNewlines)

                // Empty response → fall back. Shouldn't happen with a
                // well-formed prompt, but the model occasionally returns
                // an empty string when it can't process the input
                // (e.g. content it deems inappropriate).
                if restored.isEmpty { return rawText }

                // Length sanity check. If the model rewrote the text
                // dramatically (more than ~50% shorter or ~80% longer),
                // something went off-rails — usually a polite refusal
                // ("I'm sorry, but I can only…") or a hallucinated
                // expansion. Fall back to original to preserve content
                // integrity over having PnC.
                if Self.lengthLooksWildlyDifferent(original: rawText, restored: restored) {
                    print("[PnCRestorer] restored text length suspicious (\(restored.count) vs \(rawText.count) chars); using original.")
                    return rawText
                }

                return restored
            } catch {
                // Generation errors fall through silently — common when
                // Apple Intelligence is mid-download or under heavy
                // contention from other system features (Siri, Writing
                // Tools). Logged at info-level so you can spot them in
                // diagnostics but not noisy enough to disrupt sessions.
                print("[PnCRestorer] restoration failed: \(error.localizedDescription) — using original text.")
                return rawText
            }
        }
        #endif
        return rawText
    }

    /// Sanity check for the length of the restored text vs the original.
    /// Restoring PnC should ADD characters (punctuation, occasional
    /// uppercase letters that take the same space as lowercase) but not
    /// change word counts. A restored output that's much shorter probably
    /// means the model dropped words; much longer probably means it
    /// hallucinated, paraphrased, or appended commentary.
    ///
    /// Thresholds chosen empirically: punctuation can add up to ~15% to
    /// short conversational text, and contractions might rarely add a
    /// few percent more. 80% longer is well outside any reasonable
    /// restoration. 50% shorter is a clear sign of word removal.
    ///
    /// Skips the check for very short inputs (<10 chars) since one
    /// added punctuation mark can already push a 5-char input outside
    /// any narrow ratio.
    private static func lengthLooksWildlyDifferent(original: String, restored: String) -> Bool {
        let oLen = original.trimmingCharacters(in: .whitespacesAndNewlines).count
        let rLen = restored.trimmingCharacters(in: .whitespacesAndNewlines).count
        guard oLen > 10 else { return false }
        let ratio = Double(rLen) / Double(oLen)
        return ratio < 0.5 || ratio > 1.8
    }
}
