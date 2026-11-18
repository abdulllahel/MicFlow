import AppKit
import AVFoundation
import ScreenCaptureKit

/// Records part of a screen to an MP4 file (H.264 video, optionally the microphone as AAC) with
/// ScreenCaptureKit. MicFlow's own windows, like the recording frame, are left out.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    /// Called when the system stops the recording, e.g. when Screen Recording permission is taken away.
    var onStop: () -> Void = {}

    /// Everything below is used on this queue only, where the video and sound arrive.
    private let queue = DispatchQueue(label: "local.micboost.screen-recorder")
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var video: AVAssetWriterInput?
    private var audio: AVAssetWriterInput?
    private var microphone: AVCaptureSession?
    private var sessionStarted = false
    /// Mixes the microphone and the Mac's own sound into the one audio track.
    private var mixer: AudioMixer?
    private var mixTimer: DispatchSourceTimer?
    private var firstVideoTime: CMTime?
    private var paused = false
    private var pauseStart = CMTime.zero
    private var pausedTotal = CMTime.zero
    private var lastVideoTime = CMTime.invalid

    private static func hostNow() -> CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

    /// While paused, nothing is written; the video carries on from where it stopped, with no gap.
    func pause() {
        queue.sync {
            guard !paused else { return }
            paused = true
            pauseStart = Self.hostNow()
        }
    }

    func resume() {
        queue.sync {
            guard paused else { return }
            pausedTotal = CMTimeAdd(pausedTotal, CMTimeSubtract(Self.hostNow(), pauseStart))
            paused = false
            mixer?.discard()
        }
    }

    /// `rect` is in global Cocoa coordinates and within one screen.
    func start(rect: CGRect, microphone useMicrophone: Bool, systemAudio useSystemAudio: Bool = false, keepWindows: [CGWindowID] = [], to url: URL) async throws {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }),
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            throw Failure(errorDescription: "That area isn't on a screen.")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw Failure(errorDescription: "That screen can't be recorded.")
        }
        let ownApp = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        // MicFlow's own windows stay out of the video, except the drawing layer.
        let kept = content.windows.filter { keepWindows.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: kept)

        // The area within the display, counted from its top left.
        let local = rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        let source = CGRect(x: local.minX, y: screen.frame.height - local.maxY, width: local.width, height: local.height)
        // Full resolution, but H.264 tops out at 4096 pixels across, so a 5K screen is scaled down.
        let scale = min(screen.backingScaleFactor, 3840 / source.width, 2160 / source.height)
        let width = Int(source.width * scale) / 2 * 2
        let height = Int(source.height * scale) / 2 * 2

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = source
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.showsCursor = true
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 6
        if useSystemAudio {
            configuration.capturesAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 1
            configuration.excludesCurrentProcessAudio = true
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(width * height * 3, 2_000_000),
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        video.expectsMediaDataInRealTime = true
        writer.add(video)

        var audio: AVAssetWriterInput?
        var session: AVCaptureSession?
        var newMixer: AudioMixer?
        if useMicrophone {
            guard let device = AVCaptureDevice.default(for: .audio), let input = try? AVCaptureDeviceInput(device: device) else {
                throw Failure(errorDescription: "No microphone found.")
            }
            let capture = AVCaptureSession()
            let output = AVCaptureAudioDataOutput()
            // Plain 48 kHz mono, which the mixer takes as it is.
            output.audioSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            output.setSampleBufferDelegate(self, queue: queue)
            guard capture.canAddInput(input), capture.canAddOutput(output) else {
                throw Failure(errorDescription: "The microphone can't be recorded.")
            }
            capture.addInput(input)
            capture.addOutput(output)
            session = capture
        }
        if useMicrophone || useSystemAudio {
            let soundInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000,
            ])
            soundInput.expectsMediaDataInRealTime = true
            writer.add(soundInput)
            audio = soundInput
            newMixer = AudioMixer()
        }

        guard writer.startWriting() else {
            throw Failure(errorDescription: writer.error?.localizedDescription ?? "The video file couldn't be created.")
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if useSystemAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        queue.sync {
            self.writer = writer
            self.video = video
            self.audio = audio
            self.microphone = session
            self.stream = stream
            self.sessionStarted = false
            self.mixer = newMixer
            self.firstVideoTime = nil
            self.paused = false
            self.pausedTotal = .zero
            self.lastVideoTime = .invalid
        }
        do {
            try await stream.startCapture()
        } catch {
            writer.cancelWriting()
            queue.sync { reset() }
            throw error
        }
        session?.startRunning()
        if newMixer != nil { queue.sync { startMixing() } }
    }

    /// Every 20 ms the mixer hands the audio track whatever sound has arrived, in step with the video.
    private func startMixing() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.mixTick() }
        mixTimer = timer
        timer.resume()
    }

    private func mixTick() {
        guard let mixer, let audio, let origin = firstVideoTime, sessionStarted, !paused else { return }
        let elapsed = CMTimeSubtract(CMTimeSubtract(Self.hostNow(), origin), pausedTotal).seconds
        let wanted = Int(max(0, elapsed) * 48_000)
        while mixer.emitted + 960 <= wanted, audio.isReadyForMoreMediaData {
            let samples = mixer.nextChunk(960)
            let time = CMTimeAdd(origin, CMTime(value: CMTimeValue(mixer.emitted - 960), timescale: 48_000))
            if let buffer = AudioMixer.sampleBuffer(samples, at: time) { audio.append(buffer) }
        }
    }

    /// Finishes the file; nil if nothing was recorded.
    func stop() async -> URL? {
        let (stream, microphone) = queue.sync { (self.stream, self.microphone) }
        queue.sync { mixTimer?.cancel(); mixTimer = nil }
        try? await stream?.stopCapture()
        microphone?.stopRunning()
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard let writer, sessionStarted else {
                    writer?.cancelWriting()
                    reset()
                    return continuation.resume(returning: nil)
                }
                // Still frames aren't sent again, so end the video now rather than at the last change.
                let end = paused ? pauseStart : Self.hostNow()
                writer.endSession(atSourceTime: CMTimeSubtract(end, pausedTotal))
                video?.markAsFinished()
                audio?.markAsFinished()
                reset()
                writer.finishWriting {
                    continuation.resume(returning: writer.status == .completed ? writer.outputURL : nil)
                }
            }
        }
    }

    private func reset() {
        stream = nil
        writer = nil
        video = nil
        audio = nil
        microphone = nil
        sessionStarted = false
        mixer = nil
        mixTimer?.cancel()
        mixTimer = nil
        firstVideoTime = nil
    }

    // MARK: Samples

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            // The Mac's own sound goes into the mixer.
            if !paused, buffer.isValid, let samples = AudioMixer.floats(from: buffer) { mixer?.addSystem(samples) }
            return
        }
        guard type == .screen, !paused, buffer.isValid, let writer, let video,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: status) == .complete else { return }
        if !sessionStarted {
            writer.startSession(atSourceTime: buffer.presentationTimeStamp)
            firstVideoTime = buffer.presentationTimeStamp
            sessionStarted = true
        }
        guard video.isReadyForMoreMediaData else { return }
        var frame = buffer
        if pausedTotal != .zero {
            var timing = CMSampleTimingInfo(duration: buffer.duration, presentationTimeStamp: CMTimeSubtract(buffer.presentationTimeStamp, pausedTotal),
                                            decodeTimeStamp: .invalid)
            var copy: CMSampleBuffer?
            guard CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: buffer, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                                        sampleBufferOut: &copy) == noErr, let copy else { return }
            frame = copy
        }
        // A frame that arrives out of order (right around a pause) is skipped.
        if lastVideoTime.isValid, frame.presentationTimeStamp <= lastVideoTime { return }
        lastVideoTime = frame.presentationTimeStamp
        video.append(frame)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Sound from before the first frame is dropped, so the two start together.
        guard sessionStarted, !paused, let samples = AudioMixer.floats(from: buffer) else { return }
        mixer?.addMicrophone(samples)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop()
    }
}

/// Adds the microphone and the Mac's own sound together, as 48 kHz mono, in small steps.
final class AudioMixer {
    private var mic: [Float] = []
    private var system: [Float] = []
    private(set) var emitted = 0
    /// Never keep more than two seconds waiting.
    private let limit = 96_000

    func discard() { mic = []; system = [] }
    func addMicrophone(_ samples: [Float]) { mic += samples; if mic.count > limit { mic.removeFirst(mic.count - limit) } }
    func addSystem(_ samples: [Float]) { system += samples; if system.count > limit { system.removeFirst(system.count - limit) } }

    /// The next [count] mixed samples; a source with nothing waiting adds silence.
    func nextChunk(_ count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        let m = min(count, mic.count), s = min(count, system.count)
        for i in 0..<m { out[i] += mic[i] }
        for i in 0..<s { out[i] += system[i] }
        mic.removeFirst(m); system.removeFirst(s)
        emitted += count
        return out.map { max(-1, min(1, $0)) }
    }

    /// The samples in a sound buffer as Float, averaged to mono.
    static func floats(from buffer: CMSampleBuffer) -> [Float]? {
        guard let format = CMSampleBufferGetFormatDescription(buffer),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              let block = CMSampleBufferGetDataBuffer(buffer) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        var bytes = [UInt8](repeating: 0, count: length)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes) == kCMBlockBufferNoErr else { return nil }
        let channels = max(1, Int(description.mChannelsPerFrame))
        let isFloat = description.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let planar = description.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        var all: [Float]
        if isFloat && description.mBitsPerChannel == 32 {
            all = bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        } else if description.mBitsPerChannel == 16 {
            all = bytes.withUnsafeBytes { $0.bindMemory(to: Int16.self).map { Float($0) / 32768 } }
        } else { return nil }
        guard channels > 1 else { return all }
        let frames = all.count / channels
        var mono = [Float](repeating: 0, count: frames)
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels { sum += planar ? all[channel * frames + frame] : all[frame * channels + channel] }
            mono[frame] = sum / Float(channels)
        }
        return mono
    }

    /// A 48 kHz mono Float32 sound buffer for the writer.
    static func sampleBuffer(_ samples: [Float], at time: CMTime) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
                                               mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                             magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr, let format else { return nil }
        let size = samples.count * 4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: size, blockAllocator: nil, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: size, flags: 0, blockBufferOut: &block) == noErr, let block else { return nil }
        guard samples.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: size) }) == noErr else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: nil, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
                                   sampleCount: samples.count, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
                                   sampleSizeArray: nil, sampleBufferOut: &buffer) == noErr else { return nil }
        return buffer
    }
}
