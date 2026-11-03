import AVFoundation
import AudioToolbox
import SonataCore

/// Plays the epoch's song: one step per leader change, on macOS's General MIDI grand piano.
/// The step comes from the schedule, so every install plays the same note at the same time.
@MainActor
@Observable
final class Conductor {
    static let mutedKey = "musicMuted"
    static let volumeKey = "musicVolume"

    private(set) var position: SongPosition?
    var muted: Bool = UserDefaults.standard.bool(forKey: Conductor.mutedKey) {
        didSet {
            UserDefaults.standard.set(muted, forKey: Self.mutedKey)
            muted ? stop() : startIfNeeded()
        }
    }
    var volume: Double = UserDefaults.standard.object(forKey: Conductor.volumeKey) as? Double ?? 0.6 {
        didSet {
            UserDefaults.standard.set(volume, forKey: Self.volumeKey)
            engine?.mainMixerNode.outputVolume = Float(volume)
        }
    }

    @ObservationIgnored private let model: SonataModel
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var sampler: AVAudioUnitSampler?
    /// Notes still ringing, and how many more steps each rings for.
    @ObservationIgnored private var ringing: [UInt8: Int] = [:]
    @ObservationIgnored private var lastChange: (epoch: UInt64, change: Int)?

    static let soundBank = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")

    init(model: SonataModel) {
        self.model = model
        follow()
    }

    /// Re-runs on every leader change (the current window changing).
    private func follow() {
        withObservationTracking {
            _ = model.upcomingWindows.first
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.leaderChanged()
                self?.follow()
            }
        }
    }

    private func leaderChanged() {
        guard let window = model.upcomingWindows.first,
              let p = model.songPosition(at: window.firstSlot) else { return }
        if position?.song.id != p.song.id || position?.epoch != p.epoch || position?.change != p.change { position = p }
        guard !muted, lastChange.map({ $0.epoch != p.epoch || $0.change != p.change }) ?? true else { return }
        // A jump (a sleep, a missed handover) starts afresh instead of leaving notes hanging.
        let contiguous = lastChange.map { $0.epoch == p.epoch && $0.change + 1 == p.change } ?? false
        lastChange = (p.epoch, p.change)
        startIfNeeded()
        play(p.song.steps[p.step], releaseAll: !contiguous)
    }

    private func play(_ notes: [Song.Note], releaseAll: Bool) {
        guard let sampler else { return }
        // Age what's ringing: a note ends when its length runs out, or when it's struck again.
        for (pitch, left) in ringing {
            if releaseAll || left <= 1 || notes.contains(where: { $0.pitch == pitch }) {
                sampler.stopNote(pitch, onChannel: 0)
                ringing[pitch] = nil
            } else {
                ringing[pitch] = left - 1
            }
        }
        for note in notes {
            sampler.startNote(note.pitch, withVelocity: note.velocity, onChannel: 0)
            ringing[note.pitch] = note.length
        }
        debugLog("music: change \(lastChange?.change ?? -1) step \(position?.step ?? -1) notes \(notes.map(\.pitch))")
    }

    private func startIfNeeded() {
        guard !muted, engine == nil else { return }
        let engine = AVAudioEngine()
        let sampler = AVAudioUnitSampler()
        sampler.overallGain = 12  // dB: the GM piano is soft at these velocities
        let reverb = AVAudioUnitReverb()
        reverb.loadFactoryPreset(.mediumHall)
        reverb.wetDryMix = 28
        engine.attach(sampler)
        engine.attach(reverb)
        engine.connect(sampler, to: reverb, format: nil)
        engine.connect(reverb, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.outputVolume = Float(volume)
        do {
            // Program 0 of the General MIDI bank: the acoustic grand piano.
            try sampler.loadSoundBankInstrument(at: Self.soundBank, program: 0,
                                                bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB),
                                                bankLSB: UInt8(kAUSampler_DefaultBankLSB))
        } catch {
            debugLog("piano unavailable, using the sampler's default sound: \(error)")
        }
        do {
            try engine.start()
        } catch {
            debugLog("audio engine failed: \(error)")
            return
        }
        self.engine = engine
        self.sampler = sampler
        // SONATA_RECORD=<file.caf>: record what's played, for checking it isn't silent.
        if let path = ProcessInfo.processInfo.environment["SONATA_RECORD"] { Self.record(engine, to: path) }
    }

    /// The tap runs on the audio thread, so it must not be main-actor isolated.
    nonisolated private static func record(_ engine: AVAudioEngine, to path: String) {
        let mixer = engine.mainMixerNode
        guard let file = try? AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: mixer.outputFormat(forBus: 0).settings) else { return }
        mixer.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in try? file.write(from: buffer) }
    }

    private func stop() {
        for pitch in ringing.keys { sampler?.stopNote(pitch, onChannel: 0) }
        ringing = [:]
        lastChange = nil
        engine?.stop()
        engine = nil
        sampler = nil
    }
}
