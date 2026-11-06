import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

/// Captures the microphone as 16 kHz mono float PCM.
///
/// Latency design: in *instant* mode the input stream stays open and feeds a
/// 1-second ring buffer, so `beginCapture` is just a few writes under a lock
/// (microseconds) and the capture also includes a short pre-roll from *before*
/// the shortcut was pressed — the first syllable can never be lost. In normal
/// mode the stream is opened on demand (typically 50–150 ms).
///
/// A finished capture keeps collecting a short tail (so the last syllable is
/// not clipped) while a new capture can already start.
nonisolated final class AudioRecorder: @unchecked Sendable {
    nonisolated static let sampleRate: Double = 16_000
    nonisolated static let maxCaptureSeconds: Double = 30 * 60

    private struct Finishing {
        var samples: [Float]
        var remaining: Int
        var done = false
        var continuation: CheckedContinuation<[Float], Never>?
    }

    private struct Shared {
        var ring = [Float](repeating: 0, count: Int(AudioRecorder.sampleRate))
        var ringHead = 0
        var ringFilled = 0
        /// The capture currently being recorded.
        var active: [Float]?
        /// Captures collecting their tail.
        var finishing: [UInt64: Finishing] = [:]
        var nextID: UInt64 = 0
    }

    private let shared = Mutex(Shared())
    private let levels: AudioLevelMeter
    private let control = DispatchQueue(label: "dev.igol.flusso.audio-control", qos: .userInteractive)

    // Confined to `control`.
    private var engine: AVAudioEngine?
    private var keepWarm = false
    private var deviceUID: String?
    private var suspended = false
    private var configObserver: NSObjectProtocol?
    private var listenersInstalled = false
    /// False when a pinned device was missing and the default input was used.
    private var boundToPinnedDevice = false
    private var retryDelay: Double = 0.5
    private var retryScheduled = false

    // Confined to the audio tap thread.
    private var converter: AVAudioConverter?
    private var converterInputRate: Double = 0

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate, channels: 1, interleaved: false)!

    init(levels: AudioLevelMeter) {
        self.levels = levels
    }

    // MARK: - Public API (any thread)

    var isCapturing: Bool { shared.withLock { $0.active != nil } }

    /// `warm` keeps the stream open (instant start + pre-roll).
    func configure(warm: Bool, deviceUID: String?) {
        control.async {
            self.installDeviceListeners()
            let deviceChanged = deviceUID != self.deviceUID
            self.keepWarm = warm
            self.deviceUID = deviceUID
            if deviceChanged, self.engine != nil {
                self.stopEngine()
            }
            self.updateEngineState()
        }
    }

    /// Pauses the stream (e.g. while the Mac sleeps).
    func setSuspended(_ value: Bool) {
        control.async {
            self.suspended = value
            if value { self.stopEngine() }
            self.updateEngineState()
        }
    }

    /// Starts collecting samples. Returns `false` if a capture is running.
    @discardableResult
    func beginCapture(preRoll: Double = 0.3) -> Bool {
        let started = shared.withLock { s -> Bool in
            guard s.active == nil else { return false }
            var captured: [Float] = []
            captured.reserveCapacity(Int(Self.sampleRate) * 30)
            // Copy the most recent `preRoll` seconds from the ring.
            let wanted = min(s.ringFilled, Int(preRoll * Self.sampleRate))
            if wanted > 0 {
                let capacity = s.ring.count
                var idx = (s.ringHead - wanted + capacity) % capacity
                for _ in 0..<wanted {
                    captured.append(s.ring[idx])
                    idx = (idx + 1) % capacity
                }
            }
            s.active = captured
            return true
        }
        guard started else { return false }
        levels.reset()
        control.async { self.updateEngineState() }
        return true
    }

    /// Stops the current capture *now* (a new capture may begin immediately)
    /// and keeps collecting `tail` more seconds for it in the background.
    /// Returns a ticket for `collect(_:)`, or nil if nothing was capturing.
    func stopCapture(tail: Double = 0.15) -> UInt64? {
        let tailSamples = max(1, Int(tail * Self.sampleRate))
        let id: UInt64? = shared.withLock { s in
            guard let samples = s.active else { return nil }
            s.active = nil
            let id = s.nextID
            s.nextID += 1
            s.finishing[id] = Finishing(samples: samples, remaining: tailSamples)
            return id
        }
        if let id {
            // If the stream delivers nothing (stopped, device lost), don't wait forever.
            control.asyncAfter(deadline: .now() + tail + 0.3) { self.markDone(id) }
        }
        return id
    }

    /// Waits for a stopped capture's tail and returns all its samples.
    func collect(_ id: UInt64?) async -> [Float] {
        guard let id else { return [] }
        let result: [Float] = await withCheckedContinuation { (continuation: CheckedContinuation<[Float], Never>) in
            let ready: [Float]? = shared.withLock { s in
                guard var entry = s.finishing[id] else { return [] }
                if entry.done {
                    s.finishing.removeValue(forKey: id)
                    return entry.samples
                }
                entry.continuation = continuation
                s.finishing[id] = entry
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
        control.async { self.updateEngineState() }
        return result
    }

    /// `stopCapture` + `collect`.
    func endCapture(tail: Double = 0.15) async -> [Float] {
        await collect(stopCapture(tail: tail))
    }

    /// Drops the current capture.
    func cancelCapture() {
        shared.withLock { $0.active = nil }
        control.async { self.updateEngineState() }
    }

    /// Marks a finishing capture complete; resumes its waiter if any.
    /// Must be called with the lock *not* held.
    private func markDone(_ id: UInt64) {
        let resume: (CheckedContinuation<[Float], Never>, [Float])? = shared.withLock { s in
            guard var entry = s.finishing.removeValue(forKey: id) else { return nil }
            if let continuation = entry.continuation { return (continuation, entry.samples) }
            entry.done = true
            s.finishing[id] = entry
            return nil
        }
        if let (continuation, samples) = resume { continuation.resume(returning: samples) }
        control.async { self.updateEngineState() }
    }

    // MARK: - Engine lifecycle (control queue)

    private func updateEngineState() {
        let busy = shared.withLock { s in s.active != nil || s.finishing.values.contains { !$0.done } }
        let needed = !suspended && (keepWarm || busy)
        if needed && engine == nil {
            if startEngine() {
                retryDelay = 0.5
            } else {
                scheduleRetry()
            }
        } else if !needed && engine != nil {
            stopEngine()
        }
    }

    /// Transient failures (device switching, no input yet) are retried with backoff.
    private func scheduleRetry() {
        guard !retryScheduled else { return }
        retryScheduled = true
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 5)
        control.asyncAfter(deadline: .now() + delay) {
            self.retryScheduled = false
            self.updateEngineState()
        }
    }

    private func startEngine() -> Bool {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            Log.audio.info("Microphone not authorized; not starting stream")
            return true // not a transient failure: permission changes call configure()
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode

        boundToPinnedDevice = false
        if let uid = deviceUID, let deviceID = AudioDevices.deviceID(forUID: uid), let unit = input.audioUnit {
            boundToPinnedDevice = true
            var id = deviceID
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr { Log.audio.error("Selecting input device failed: \(status)") }
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            Log.audio.error("No usable input format")
            return false
        }

        input.installTap(onBus: 0, bufferSize: 512, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            Log.audio.error("Audio engine start failed: \(error.localizedDescription)")
            input.removeTap(onBus: 0)
            return false
        }

        self.engine = engine
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.control.async {
                Log.audio.info("Audio configuration changed; restarting stream")
                self.stopEngine()
                self.updateEngineState()
            }
        }
        Log.audio.info("Input stream started (\(format.sampleRate, format: .fixed(precision: 0)) Hz, \(format.channelCount) ch)")
        return true
    }

    private func stopEngine() {
        guard let engine else { return }
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        // Drop stale pre-roll so it is never prepended to a later capture.
        shared.withLock { s in
            s.ringFilled = 0
            s.ringHead = 0
        }
        Log.audio.info("Input stream stopped")
    }

    /// Follows the system default input (when no device is pinned) and
    /// recovers when devices appear, independently of a live engine.
    private func installDeviceListeners() {
        guard !listenersInstalled else { return }
        listenersInstalled = true
        let system = AudioObjectID(kAudioObjectSystemObject)
        var defaultInput = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(system, &defaultInput, control) { [weak self] _, _ in
            guard let self, self.deviceUID == nil else { return }
            Log.audio.info("Default input device changed")
            self.stopEngine()
            self.updateEngineState()
        }
        var devices = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(system, &devices, control) { [weak self] _, _ in
            guard let self else { return }
            if self.engine == nil {
                self.retryDelay = 0.5
                self.updateEngineState()
            } else if let uid = self.deviceUID, !self.boundToPinnedDevice,
                      AudioDevices.deviceID(forUID: uid) != nil {
                // The pinned device (re)appeared while we were on the default: rebind.
                self.stopEngine()
                self.updateEngineState()
            }
        }
    }

    // MARK: - Audio thread

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frames > 0 else { return }
        let sourceRate = buffer.format.sampleRate

        // Downmix to mono at the hardware rate.
        guard let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceRate,
                                             channels: 1, interleaved: false),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(frames)),
              let monoData = mono.floatChannelData?[0] else { return }
        mono.frameLength = AVAudioFrameCount(frames)
        if channelCount == 1 {
            monoData.update(from: channels[0], count: frames)
        } else {
            let scale = 1 / Float(channelCount)
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<channelCount { sum += channels[c][i] }
                monoData[i] = sum * scale
            }
        }

        // Waveform levels (~20 ms per value) while capturing.
        if isCapturing {
            let chunk = max(1, Int(sourceRate / 50))
            var offset = 0
            while offset < frames {
                let n = min(chunk, frames - offset)
                var sum: Float = 0
                for i in offset..<(offset + n) { sum += monoData[i] * monoData[i] }
                levels.push(AudioLevelMeter.normalize(rms: (sum / Float(n)).squareRoot()))
                offset += n
            }
        }

        // Resample to 16 kHz.
        let samples: [Float]
        if sourceRate == Self.sampleRate {
            samples = Array(UnsafeBufferPointer(start: monoData, count: frames))
        } else {
            if converter == nil || converterInputRate != sourceRate {
                converter = AVAudioConverter(from: monoFormat, to: targetFormat)
                converterInputRate = sourceRate
            }
            guard let converter else { return }
            let capacity = AVAudioFrameCount(Double(frames) * Self.sampleRate / sourceRate) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if supplied {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return mono
            }
            if let error {
                Log.audio.error("Resampling failed: \(error.localizedDescription)")
                return
            }
            guard let data = out.floatChannelData?[0] else { return }
            samples = Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
        }

        let maxSamples = Int(Self.maxCaptureSeconds * Self.sampleRate)
        var completed: [(CheckedContinuation<[Float], Never>, [Float])] = []
        var anyDone = false
        shared.withLock { s in
            if s.active != nil, s.active!.count < maxSamples {
                s.active!.append(contentsOf: samples)
            }
            for id in Array(s.finishing.keys) {
                // Remove before mutating so the array isn't copied (CoW).
                guard var entry = s.finishing.removeValue(forKey: id) else { continue }
                if !entry.done {
                    let n = min(entry.remaining, samples.count)
                    entry.samples.append(contentsOf: samples[0..<n])
                    entry.remaining -= n
                    if entry.remaining <= 0 {
                        anyDone = true
                        if let continuation = entry.continuation {
                            completed.append((continuation, entry.samples))
                            continue
                        }
                        entry.done = true
                    }
                }
                s.finishing[id] = entry
            }
            let capacity = s.ring.count
            for sample in samples {
                s.ring[s.ringHead] = sample
                s.ringHead = (s.ringHead + 1) % capacity
            }
            s.ringFilled = min(capacity, s.ringFilled + samples.count)
        }
        for (continuation, captured) in completed {
            continuation.resume(returning: captured)
        }
        if anyDone {
            control.async { self.updateEngineState() }
        }
    }
}
