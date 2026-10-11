import AVFoundation

/// The renderer calls the pipeline makes, so tests can drive backpressure.
protocol VideoFrameRenderer: AnyObject {
    var status: AVQueuedSampleBufferRenderingStatus { get }
    var requiresFlushToResumeDecoding: Bool { get }
    var isReadyForMoreMediaData: Bool { get }
    func enqueue(_ sampleBuffer: CMSampleBuffer)
    func flush()
    /// Flushes and also removes the image currently on screen.
    func flushAndClear()
}

extension AVSampleBufferVideoRenderer: VideoFrameRenderer {
    func flushAndClear() { flush(removingDisplayedImage: true, completionHandler: nil) }
}

/// Annex B chunks in, hardware-decoded frames on screen. Use only from the session queue.
final class VideoPipeline {
    private let renderer: VideoFrameRenderer
    private var parser = AnnexBParser()
    private var assembler = AccessUnitAssembler()
    private var format: CMVideoFormatDescription?
    private var formatSets: H264ParameterSets?
    private(set) var enqueuedFrames = 0
    private(set) var droppedFrames = 0
    /// The decoded picture's display size, once a format is known. Input maps through its aspect-fit rectangle.
    private(set) var presentationSize: CGSize?

    init(renderer: VideoFrameRenderer) {
        self.renderer = renderer
    }

    /// Returns true when this chunk put the session's first frame on screen.
    func consume(_ chunk: Data) -> Bool {
        let before = enqueuedFrames
        for event in parser.append(chunk) {
            if let unit = assembler.consume(event) { display(unit) }
        }
        return before == 0 && enqueuedFrames > 0
    }

    /// Called on disconnect: the protocol resets parser and decoder, and the last partial picture is dropped.
    func reset() {
        parser.reset()
        assembler.reset()
        format = nil
        formatSets = nil
        enqueuedFrames = 0
        droppedFrames = 0
        presentationSize = nil
        renderer.flushAndClear()
    }

    private func display(_ unit: AccessUnit) {
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush()
            guard unit.isIDR else {
                assembler.requestIDR()
                return
            }
        }

        // Backpressure: never queue more than the renderer accepts. A dropped picture breaks the
        // reference chain, so the P pictures that depend on it are skipped until the next IDR.
        guard renderer.isReadyForMoreMediaData else {
            droppedFrames += 1
            assembler.requestIDR()
            return
        }

        do {
            if format == nil || formatSets != unit.parameterSets {
                format = try H264SampleBuilder.formatDescription(for: unit.parameterSets)
                formatSets = unit.parameterSets
                if let format {
                    presentationSize = CMVideoFormatDescriptionGetPresentationDimensions(
                        format, usePixelAspectRatio: true, useCleanAperture: true)
                }
            }
            guard let format else { return }
            renderer.enqueue(try H264SampleBuilder.sampleBuffer(for: unit, format: format))
            enqueuedFrames += 1
        } catch {
            format = nil
            formatSets = nil
            assembler.requestIDR()
        }
    }
}
