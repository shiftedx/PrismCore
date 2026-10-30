import Foundation
import Libavcodec
import Libavformat
import Libavutil
import Testing
@testable import PrismCore

@Suite(
    "M2TS cold keyframe scout",
    .enabled(if: ProcessInfo.processInfo.environment["PRISMCORE_DV7_M2TS_COLD_SEEK_FIXTURE"] != nil)
)
struct M2TSColdKeyframeScoutTests {

    @Test("a complete sparse map starts at the real head IRAP and leaves the context there")
    func completeMapIsUsableAfterRewind() throws {
        var opened = try openFixture()
        defer { avformat_close_input(&opened.context) }
        let stream = try #require(opened.context?.pointee.streams[1])

        let result = M2TSColdKeyframeScout.completeSparsePlan(
            input: try #require(opened.context), baseStreamIndex: 1,
            timeBase: stream.pointee.time_base,
            timelineEndPTS: stream.pointee.start_time + stream.pointee.duration,
            targetSeconds: 6, firstSegmentSeconds: SegmentPlan.defaultFirstSegmentSeconds,
            interruptGuard: opened.guardBox
        )
        guard case let .complete(keyframes) = result else {
            Issue.record("Expected a complete observed cold keyframe map, got \(result)")
            return
        }
        #expect(!result.rewindRequired)
        let first = try #require(keyframes.first)
        #expect(first == 7_500)
        #expect(keyframes.count > 2)
        #expect(try firstBaseIRAP(in: try #require(opened.context), streamIndex: 1) == 7_500)
    }

    @Test("a byte or clock-starved sparse proof never publishes a map")
    func boundedScoutFallsBackWithoutMap() throws {
        var byteStarved = try openFixture()
        defer { avformat_close_input(&byteStarved.context) }
        let byteStream = try #require(byteStarved.context?.pointee.streams[1])
        let byteResult = M2TSColdKeyframeScout.completeSparsePlan(
            input: try #require(byteStarved.context), baseStreamIndex: 1,
            timeBase: byteStream.pointee.time_base,
            timelineEndPTS: byteStream.pointee.start_time + byteStream.pointee.duration,
            targetSeconds: 6, firstSegmentSeconds: SegmentPlan.defaultFirstSegmentSeconds,
            interruptGuard: byteStarved.guardBox,
            byteBudget: 1
        )
        assertInsufficient(byteResult)

        var clockStarved = try openFixture()
        defer { avformat_close_input(&clockStarved.context) }
        let clockStream = try #require(clockStarved.context?.pointee.streams[1])
        let clockResult = M2TSColdKeyframeScout.completeSparsePlan(
            input: try #require(clockStarved.context), baseStreamIndex: 1,
            timeBase: clockStream.pointee.time_base,
            timelineEndPTS: clockStream.pointee.start_time + clockStream.pointee.duration,
            targetSeconds: 6, firstSegmentSeconds: SegmentPlan.defaultFirstSegmentSeconds,
            interruptGuard: clockStarved.guardBox,
            timeBudget: .zero
        )
        assertInsufficient(clockResult)

        var cancelled = try openFixture()
        defer { avformat_close_input(&cancelled.context) }
        let cancelledStream = try #require(cancelled.context?.pointee.streams[1])
        cancelled.guardBox.cancel()
        let cancelledResult = M2TSColdKeyframeScout.completeSparsePlan(
            input: try #require(cancelled.context), baseStreamIndex: 1,
            timeBase: cancelledStream.pointee.time_base,
            timelineEndPTS: cancelledStream.pointee.start_time + cancelledStream.pointee.duration,
            targetSeconds: 6, firstSegmentSeconds: SegmentPlan.defaultFirstSegmentSeconds,
            interruptGuard: cancelled.guardBox
        )
        guard case .cancelled = cancelledResult else {
            Issue.record("Expected cancellation to remain distinct from an insufficient proof, got \(cancelledResult)")
            return
        }
    }

    @Test("a host input that dies after open remains an I/O failure")
    func postOpenHostReadFailureIsNotAnInsufficientPrefix() throws {
        let path = try fixturePath()
        let source = try Data(contentsOf: URL(fileURLWithPath: path))
        let input = ScoutFaultingInput(data: source)
        let guardBox = ReadInterruptGuard()
        var context: UnsafeMutablePointer<AVFormatContext>? = guardBox.makeContext()
        let allocated = try #require(context)
        try guardBox.installCustomInput(on: allocated, factory: { input })
        try FFmpegError.check(
            avformat_open_input(&context, nil, nil, nil), "avformat_open_input(M2TS cold scout fault test)"
        )
        defer { avformat_close_input(&context) }
        let opened = try #require(context)
        try FFmpegError.check(
            avformat_find_stream_info(opened, nil), "avformat_find_stream_info(M2TS cold scout fault test)"
        )
        let stream = try #require(opened.pointee.streams[1])
        input.failSubsequentReads()

        let result = M2TSColdKeyframeScout.completeSparsePlan(
            input: opened, baseStreamIndex: 1, timeBase: stream.pointee.time_base,
            timelineEndPTS: stream.pointee.start_time + stream.pointee.duration,
            targetSeconds: 6, firstSegmentSeconds: SegmentPlan.defaultFirstSegmentSeconds,
            interruptGuard: guardBox
        )
        guard case let .ioFailure(code, _, _) = result else {
            Issue.record("Expected post-open custom-input I/O failure, got \(result)")
            return
        }
        #expect(code < 0)
        #expect(guardBox.customInputFailure != nil)
    }

    private func assertInsufficient(_ result: M2TSColdKeyframeScout.CompleteResult) {
        guard case .insufficient = result else {
            Issue.record("A budget-starved scout must be insufficient, got \(result)")
            return
        }
    }

    private func openFixture() throws -> (
        guardBox: ReadInterruptGuard, context: UnsafeMutablePointer<AVFormatContext>?
    ) {
        let guardBox = ReadInterruptGuard()
        var context: UnsafeMutablePointer<AVFormatContext>? = guardBox.makeContext()
        try FFmpegError.check(
            avformat_open_input(&context, try fixturePath(), nil, nil),
            "avformat_open_input(M2TS cold scout fixture)"
        )
        let opened = try #require(context)
        try FFmpegError.check(
            avformat_find_stream_info(opened, nil), "avformat_find_stream_info(M2TS cold scout fixture)"
        )
        return (guardBox, context)
    }

    private func fixturePath() throws -> String {
        try #require(ProcessInfo.processInfo.environment["PRISMCORE_DV7_M2TS_COLD_SEEK_FIXTURE"])
    }

    private func firstBaseIRAP(
        in input: UnsafeMutablePointer<AVFormatContext>, streamIndex: Int32
    ) throws -> Int64? {
        var ownedPacket = av_packet_alloc()
        defer { av_packet_free(&ownedPacket) }
        let packet = try #require(ownedPacket)
        while av_read_frame(input, packet) >= 0 {
            defer { av_packet_unref(packet) }
            guard packet.pointee.stream_index == streamIndex,
                  packet.pointee.pts != swift_AV_NOPTS_VALUE(),
                  let data = packet.pointee.data,
                  packet.pointee.size > 0
            else { continue }
            let bytes = UnsafeBufferPointer(start: data, count: Int(packet.pointee.size))
            if let units = HEVCNALUnits.strictUnits(in: bytes, framing: .annexB),
               units.contains(where: { (16...21).contains(Int($0.type)) }) {
                return packet.pointee.pts
            }
        }
        return nil
    }
}

private final class ScoutFaultingInput: PrismCoreInput, @unchecked Sendable {
    struct Broken: Error {}

    private let bytes: [UInt8]
    private let lock = NSLock()
    private var position = 0
    private var failReads = false

    init(data: Data) { bytes = [UInt8](data) }

    var length: Int64? { Int64(bytes.count) }

    func failSubsequentReads() {
        lock.withLock { failReads = true }
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        try lock.withLock {
            if failReads { throw Broken() }
            let count = min(buffer.count, bytes.count - position)
            guard count > 0 else { return 0 }
            bytes.withUnsafeBytes { source in
                buffer.baseAddress!.copyMemory(from: source.baseAddress!.advanced(by: position), byteCount: count)
            }
            position += count
            return count
        }
    }

    func seek(to offset: Int64) throws {
        lock.withLock { position = Int(max(0, min(offset, Int64(bytes.count)))) }
    }
}
