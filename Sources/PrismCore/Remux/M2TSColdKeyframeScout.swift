import Foundation
import Libavcodec
import Libavformat
import Libavutil

/// Bounded complete evidence for a separately-carried M2TS Dolby Vision source.
///
/// MPEG-TS index entries follow transport timestamps, not necessarily independently decodable
/// HEVC pictures. An immutable VOD can therefore use only the actual base-layer IRAPs this scout
/// observes; a source that cannot prove the whole map inside its budget remains sequential.
enum M2TSColdKeyframeScout {

    /// Six seconds of a 60 Mb/s transport can occupy about 45 MiB. Leave room for a real GOP,
    /// while keeping a malformed or unexpectedly interleaved input from stealing cold startup.
    static let byteBudget: Int64 = 64 << 20
    static let timeBudget: Duration = .seconds(2)

    /// A complete sparse map for strict transport sessions. Every returned value is an observed
    /// base-layer IRAP and the final packet walk reached EOF; no tail cadence is inferred.
    enum CompleteResult {
        case complete([Int64])
        case insufficient(rewindRequired: Bool)
        case cancelled(rewindRequired: Bool)
        case ioFailure(code: Int32, operation: String, rewindRequired: Bool)

        var rewindRequired: Bool {
            switch self {
            case .complete: false
            case let .insufficient(rewindRequired), let .cancelled(rewindRequired): rewindRequired
            case let .ioFailure(_, _, rewindRequired): rewindRequired
            }
        }
    }

    /// Finds the real IRAPs that become the immutable VOD's segment starts. A timestamp seek
    /// is only a locality hint; the packet walk proves the selected start. The budget covers all
    /// seeks, reads and the final head reset, so a slow source simply remains sequential.
    static func completeSparsePlan(
        input: UnsafeMutablePointer<AVFormatContext>,
        baseStreamIndex: Int32,
        timeBase: AVRational,
        timelineEndPTS: Int64,
        targetSeconds: Int,
        firstSegmentSeconds: Int,
        interruptGuard: ReadInterruptGuard,
        byteBudget: Int64 = byteBudget,
        timeBudget: Duration = timeBudget
    ) -> CompleteResult {
        guard baseStreamIndex >= 0, baseStreamIndex < input.pointee.nb_streams,
              timeBase.num > 0, timeBase.den > 0, timelineEndPTS > 0,
              targetSeconds > 0, firstSegmentSeconds > 0, byteBudget > 0,
              let pb = input.pointee.pb, pb.pointee.bytes_read >= 0
        else { return .insufficient(rewindRequired: false) }

        let initialBytesRead = pb.pointee.bytes_read
        let started = ContinuousClock.now
        var ownedPacket = av_packet_alloc()
        guard let packet = ownedPacket else { return .insufficient(rewindRequired: false) }
        defer { av_packet_free(&ownedPacket) }
        interruptGuard.arm(budget: timeBudget)
        defer { interruptGuard.disarm() }

        func elapsedBudget() -> Bool {
            ContinuousClock.now - started >= timeBudget
        }
        func expired() -> Bool {
            interruptGuard.shouldInterrupt || elapsedBudget()
        }
        func inBudget() -> Bool {
            let read = pb.pointee.bytes_read
            return read >= initialBytesRead && read - initialBytesRead < byteBudget
        }
        func interrupted(rewindRequired: Bool) -> CompleteResult {
            elapsedBudget() ? .insufficient(rewindRequired: rewindRequired)
                : .cancelled(rewindRequired: rewindRequired)
        }
        func resetToHead(rewindRequiredOnFailure: Bool) -> CompleteResult? {
            let seek = av_seek_frame(input, baseStreamIndex, 0, AVSEEK_FLAG_BACKWARD)
            guard seek >= 0 else {
                return expired()
                    ? interrupted(rewindRequired: rewindRequiredOnFailure)
                    : .ioFailure(code: seek, operation: "av_seek_frame(M2TS sparse keyframe scout head)", rewindRequired: rewindRequiredOnFailure)
            }
            avformat_flush(input)
            return expired() ? interrupted(rewindRequired: false) : nil
        }
        func finish(_ result: CompleteResult) -> CompleteResult {
            if let failure = resetToHead(rewindRequiredOnFailure: true) { return failure }
            guard inBudget() else {
                switch result {
                case .complete, .insufficient: return .insufficient(rewindRequired: false)
                case .cancelled, .ioFailure: return result
                }
            }
            return result
        }

        enum Read { case irap(Int64), eof, stop(CompleteResult) }
        func nextIRAP(atOrAfter minimumPTS: Int64?) -> Read {
            while true {
                guard !expired(), inBudget() else {
                    return .stop(expired() ? interrupted(rewindRequired: false) : .insufficient(rewindRequired: false))
                }
                let read = av_read_frame(input, packet)
                guard read >= 0 else {
                    if expired() { return .stop(interrupted(rewindRequired: false)) }
                    if read == swift_AVERROR_EOF() {
                        if pb.pointee.error < 0, pb.pointee.error != swift_AVERROR_EOF() {
                            return .stop(.ioFailure(code: pb.pointee.error, operation: "AVIOContext.error(M2TS sparse keyframe scout)", rewindRequired: false))
                        }
                        return .eof
                    }
                    return .stop(.ioFailure(code: read, operation: "av_read_frame(M2TS sparse keyframe scout)", rewindRequired: false))
                }
                defer { av_packet_unref(packet) }
                guard inBudget() else { return .stop(.insufficient(rewindRequired: false)) }
                guard packet.pointee.stream_index == baseStreamIndex,
                      packet.pointee.pts != swift_AV_NOPTS_VALUE(),
                      let data = packet.pointee.data, packet.pointee.size > 0
                else { continue }
                let bytes = UnsafeBufferPointer(start: data, count: Int(packet.pointee.size))
                guard let units = HEVCNALUnits.strictUnits(in: bytes, framing: .annexB),
                      units.allSatisfy({ $0.layerID == 0 && $0.type != 62 && $0.type != 63 }),
                      units.contains(where: { (16...21).contains(Int($0.type)) })
                else { continue }
                let pts = packet.pointee.pts
                if minimumPTS == nil || pts >= minimumPTS! { return .irap(pts) }
            }
        }

        if let failure = resetToHead(rewindRequiredOnFailure: true) { return finish(failure) }
        let tickSeconds = av_q2d(timeBase)
        guard tickSeconds.isFinite, tickSeconds > 0 else { return finish(.insufficient(rewindRequired: false)) }

        var witnessed: [Int64] = []
        witnessLoop: while true {
            switch nextIRAP(atOrAfter: nil) {
            case let .irap(pts):
                guard witnessed.last.map({ pts > $0 }) ?? true else {
                    return finish(.insufficient(rewindRequired: false))
                }
                guard witnessed.count < SourceStructure.maxExportedKeyframes else {
                    return finish(.insufficient(rewindRequired: false))
                }
                witnessed.append(pts)
                if witnessed.count >= 2, let first = witnessed.first, let last = witnessed.last,
                   Double(last - first) * tickSeconds >= Double(SegmentPlan.witnessSeconds) { break witnessLoop }
            case .eof: return finish(.insufficient(rewindRequired: false))
            case let .stop(result): return finish(result)
            }
        }

        guard let first = witnessed.first else { return finish(.insufficient(rewindRequired: false)) }
        var anchors = [first]
        let firstStep = Int64((Double(min(firstSegmentSeconds, targetSeconds)) / tickSeconds).rounded(.up))
        let step = Int64((Double(targetSeconds) / tickSeconds).rounded(.up))
        while true {
            let distance = anchors.count == 1 ? firstStep : step
            let (desired, overflow) = anchors[anchors.count - 1].addingReportingOverflow(distance)
            guard !overflow else { return finish(.insufficient(rewindRequired: false)) }
            if desired >= timelineEndPTS { break }
            let sought = av_seek_frame(input, baseStreamIndex, desired, AVSEEK_FLAG_BACKWARD)
            guard sought >= 0, !expired() else {
                if expired() { return finish(interrupted(rewindRequired: false)) }
                return finish(.ioFailure(code: sought, operation: "av_seek_frame(M2TS sparse keyframe scout)", rewindRequired: false))
            }
            avformat_flush(input)
            switch nextIRAP(atOrAfter: desired) {
            case let .irap(pts):
                let gap = Double(pts - anchors[anchors.count - 1]) * tickSeconds
                guard pts > anchors[anchors.count - 1], pts < timelineEndPTS,
                      gap <= SegmentPlan.maxTrustedGapSeconds
                else { return finish(.insufficient(rewindRequired: false)) }
                guard anchors.count < SourceStructure.maxExportedKeyframes else {
                    return finish(.insufficient(rewindRequired: false))
                }
                anchors.append(pts)
            case .eof:
                // This is a measured final tail, not an inferred cadence. It can be longer than
                // the requested target, but only inside the same maximum gap the plan accepts.
                let tail = Double(timelineEndPTS - anchors[anchors.count - 1]) * tickSeconds
                return finish(tail > 0 && tail <= SegmentPlan.maxTrustedGapSeconds
                    ? .complete(anchors) : .insufficient(rewindRequired: false))
            case let .stop(result): return finish(result)
            }
        }

        // The remaining tail is shorter than a target. Read it to EOF so the final playlist
        // entry is a measured endpoint rather than an assumed cadence.
        while true {
            switch nextIRAP(atOrAfter: nil) {
            case .irap: continue
            case .eof: return finish(.complete(anchors))
            case let .stop(result): return finish(result)
            }
        }
    }

}
