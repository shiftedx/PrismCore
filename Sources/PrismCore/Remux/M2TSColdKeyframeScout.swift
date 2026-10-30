import Foundation
import Libavcodec
import Libavformat
import Libavutil

/// Bounded evidence for the head prefix of a separately-carried M2TS Dolby Vision source.
///
/// MPEG-TS index entries follow transport timestamps, not necessarily independently decodable
/// HEVC pictures. A cold session may use this observed prefix as a *partial* segment-plan seed,
/// but only after it has seen actual base-layer IRAP NALs. It never persists the result: a later
/// producer harvest is still the only evidence for the rest of the source.
enum M2TSColdKeyframeScout {

    /// Six seconds of a 60 Mb/s transport can occupy about 45 MiB. Leave room for a real GOP,
    /// while keeping a malformed or unexpectedly interleaved input from stealing cold startup.
    static let byteBudget: Int64 = 64 << 20
    static let timeBudget: Duration = .seconds(2)

    enum Result {
        /// A contiguous observed head prefix. `coveredThroughPTS` is the final observed IRAP.
        case success([Int64], Int64)
        /// EOF, the scout's budget, or insufficient actual IRAP evidence. Sequential copy is safe.
        case insufficient(rewindRequired: Bool)
        /// A caller cancellation, distinct from an ordinary absence of enough evidence.
        case cancelled(rewindRequired: Bool)
        /// A source read or head-seek failure; callers must preserve its typed source diagnosis.
        case ioFailure(code: Int32, operation: String, rewindRequired: Bool)

        /// A successful head reset makes the context ready for `SegmentPlan` or the copy loop.
        /// When it is true, the caller must reopen rather than treating a half-read demuxer as
        /// sequential input.
        var rewindRequired: Bool {
            switch self {
            case .success:
                return false
            case let .insufficient(rewindRequired), let .cancelled(rewindRequired):
                return rewindRequired
            case let .ioFailure(_, _, rewindRequired):
                return rewindRequired
            }
        }
    }

    /// Scan a head prefix from an already-open source. The packet cursor inherited from a probe
    /// is deliberately ignored: a partial map means contiguous coverage from the source head.
    ///
    /// The guard is the one installed before this context opened. It bounds both head seeks and
    /// reads; a later guard cannot interrupt libavformat's underlying URL context.
    static func scan(
        input: UnsafeMutablePointer<AVFormatContext>,
        baseStreamIndex: Int32,
        timeBase: AVRational,
        interruptGuard: ReadInterruptGuard,
        byteBudget: Int64 = byteBudget,
        timeBudget: Duration = timeBudget
    ) -> Result {
        guard baseStreamIndex >= 0,
              baseStreamIndex < input.pointee.nb_streams,
              timeBase.num > 0,
              timeBase.den > 0,
              byteBudget > 0
        else { return .insufficient(rewindRequired: false) }

        // Start before the first seek: transport seeks can themselves refill AVIO, and an
        // optional startup scout has no right to hide those reads outside its byte budget.
        guard let pb = input.pointee.pb, pb.pointee.bytes_read >= 0 else {
            return .insufficient(rewindRequired: false)
        }
        let initialBytesRead = pb.pointee.bytes_read

        var ownedPacket = av_packet_alloc()
        guard let packet = ownedPacket else {
            return .insufficient(rewindRequired: false)
        }
        defer { av_packet_free(&ownedPacket) }

        let started = ContinuousClock.now
        interruptGuard.arm(budget: timeBudget)
        defer { interruptGuard.disarm() }

        func elapsedBudget() -> Bool {
            ContinuousClock.now - started >= timeBudget
        }

        func interruptionResult(rewindRequired: Bool) -> Result {
            // The scout's own deadline is an absence of sufficient evidence. A cancellation
            // before that deadline is a different control-flow signal and must not look like a
            // normal cold-start fallback.
            elapsedBudget()
                ? .insufficient(rewindRequired: rewindRequired)
                : .cancelled(rewindRequired: rewindRequired)
        }

        func bytesRemainWithinBudget() -> Bool {
            let bytesRead = pb.pointee.bytes_read
            return bytesRead >= initialBytesRead && bytesRead - initialBytesRead < byteBudget
        }

        func resetToHead(rewindRequiredOnFailure: Bool) -> Result? {
            // The PMT may place the EL first. Seeking the demuxer's default
            // stream at the head can then skip the opening BL IRAP; anchor
            // every reset to the selected base stream instead.
            let seek = av_seek_frame(input, baseStreamIndex, 0, AVSEEK_FLAG_BACKWARD)
            guard seek >= 0 else {
                return interruptGuard.shouldInterrupt
                    ? interruptionResult(rewindRequired: rewindRequiredOnFailure)
                    : .ioFailure(
                        code: seek, operation: "av_seek_frame(M2TS cold keyframe scout head)",
                        rewindRequired: rewindRequiredOnFailure
                    )
            }
            avformat_flush(input)
            if interruptGuard.shouldInterrupt {
                // The seek and flush completed, so even a deadline/cancellation observed just
                // afterwards leaves a valid head cursor for the caller's sequential fallback.
                return interruptionResult(rewindRequired: false)
            }
            return nil
        }

        /// Every path that moved the demuxer attempts this final reset. A transport that cannot
        /// restore its head is not safe for a sequential fallback on this context.
        func finish(_ result: Result) -> Result {
            if let resetFailure = resetToHead(rewindRequiredOnFailure: true) {
                return resetFailure
            }
            guard bytesRemainWithinBudget() else {
                // Preserve a real read/cancellation diagnosis over the optional scout's cap.
                switch result {
                case .success, .insufficient:
                    return .insufficient(rewindRequired: false)
                case .cancelled, .ioFailure:
                    return result
                }
            }
            return result
        }

        if let initialResetFailure = resetToHead(rewindRequiredOnFailure: true) {
            return finish(initialResetFailure)
        }

        guard bytesRemainWithinBudget() else { return finish(.insufficient(rewindRequired: false)) }

        let tickSeconds = av_q2d(timeBase)
        guard tickSeconds.isFinite, tickSeconds > 0 else {
            return finish(.insufficient(rewindRequired: false))
        }

        var keyframes: [Int64] = []
        while true {
            if interruptGuard.shouldInterrupt {
                return finish(interruptionResult(rewindRequired: false))
            }
            guard bytesRemainWithinBudget() else {
                return finish(.insufficient(rewindRequired: false))
            }

            let read = av_read_frame(input, packet)
            guard read >= 0 else {
                if interruptGuard.shouldInterrupt {
                    return finish(interruptionResult(rewindRequired: false))
                }
                if read == swift_AVERROR_EOF() {
                    if pb.pointee.error < 0, pb.pointee.error != swift_AVERROR_EOF() {
                        return finish(.ioFailure(
                            code: pb.pointee.error,
                            operation: "AVIOContext.error(M2TS cold keyframe scout)",
                            rewindRequired: false
                        ))
                    }
                    return finish(.insufficient(rewindRequired: false))
                }
                return finish(.ioFailure(
                    code: read, operation: "av_read_frame(M2TS cold keyframe scout)", rewindRequired: false
                ))
            }
            defer { av_packet_unref(packet) }

            // `av_read_frame` can refill a full AVIO buffer in one call. Check after it too, or a
            // source whose packet happens to contain the witness IRAP could qualify beyond cap.
            guard bytesRemainWithinBudget() else { return finish(.insufficient(rewindRequired: false)) }

            guard packet.pointee.stream_index == baseStreamIndex,
                  packet.pointee.pts != swift_AV_NOPTS_VALUE(),
                  let data = packet.pointee.data,
                  packet.pointee.size > 0
            else { continue }

            let bytes = UnsafeBufferPointer(start: data, count: Int(packet.pointee.size))
            guard let units = HEVCNALUnits.strictUnits(in: bytes, framing: .annexB),
                  units.contains(where: { (16...21).contains(Int($0.type)) })
            else { continue }

            let pts = packet.pointee.pts
            guard keyframes.last.map({ pts > $0 }) ?? true else {
                // A partial plan must be chronological. Sorting decode-order observations would
                // manufacture continuity around B-frame or malformed timestamp discontinuities.
                return finish(.insufficient(rewindRequired: false))
            }
            guard keyframes.count < SourceStructure.maxExportedKeyframes else {
                // A byte cap alone permits a malicious all-intra stream of tiny access units to
                // turn this optional startup hint into an unbounded timestamp allocation.
                return finish(.insufficient(rewindRequired: false))
            }
            keyframes.append(pts)

            if keyframes.count >= 2,
               let first = keyframes.first, let last = keyframes.last,
               (Double(last) - Double(first)) * tickSeconds >= Double(SegmentPlan.witnessSeconds) {
                return finish(.success(keyframes, last))
            }
        }
    }
}
