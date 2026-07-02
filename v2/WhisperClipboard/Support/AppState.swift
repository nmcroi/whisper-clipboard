import Foundation

/// High-level lifecycle state of the app, surfaced in the menu bar and Home view.
///
/// The Dutch `statusText` mirrors the tone of the Python v1 `status.py` messages.
enum AppState: Equatable {
    case starting
    case loadingModel
    case ready
    case recording
    case transcribing
    case error(String)

    /// User-facing Dutch status line.
    var statusText: String {
        switch self {
        case .starting:
            return "Bezig met opstarten…"
        case .loadingModel:
            return "Model laden…"
        case .ready:
            return "Klaar voor opname"
        case .recording:
            return "Opname loopt"
        case .transcribing:
            return "Transcriptie maken…"
        case .error(let message):
            return "Fout: \(message)"
        }
    }

    /// SF Symbol name representing the state in the status item.
    var symbolName: String {
        switch self {
        case .starting, .loadingModel:
            return "hourglass"
        case .ready:
            return "mic"
        case .recording:
            return "mic.fill"
        case .transcribing:
            return "waveform"
        case .error:
            return "mic.slash"
        }
    }

    /// Whether the state represents active recording (drives the tinted status icon).
    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
}
