import Foundation
import Libavformat
import Libavutil
import Testing
@testable import PrismCore

/// The byte-array scanner is pure. These checks cover its other trust
/// boundary: an already-open AVIO context must distinguish source failure
/// from a transport stream that merely lacks the required Dolby Vision proof.
struct M2TSDolbyVisionScannerIOTests {
    @Test("a custom input read error is not parsed as an absent M2TS association")
    func customReadFailureRemainsIOFailure() throws {
        let input = ScannerInput()
        let guardBox = ReadInterruptGuard()
        let context = try #require(guardBox.makeContext())
        defer { avformat_free_context(context) }
        try guardBox.installCustomInput(on: context, factory: { input })

        let verdict = M2TSDolbyVisionAssociation.scan(input: context, interruptGuard: guardBox)
        guard case .ioFailure = verdict else {
            Issue.record("Expected custom-input read failure, got \(verdict)")
            return
        }
    }

    @Test("a live AVIO seek failure is not parsed as an absent M2TS association")
    func seekFailureRemainsIOFailure() throws {
        let guardBox = ReadInterruptGuard()
        let context = try #require(guardBox.makeContext())
        let harness = DirectSeekFailureAVIO()
        let io = try harness.install(on: context)
        defer {
            context.pointee.pb = nil
            var owned: UnsafeMutablePointer<AVIOContext>? = io
            avio_context_free(&owned)
            avformat_free_context(context)
        }
        // A position outside AVIO's empty buffer makes the scanner's required
        // rewind a real callback, rather than a cache-local no-op.
        io.pointee.pos = 384

        let verdict = M2TSDolbyVisionAssociation.scan(input: context, interruptGuard: guardBox)
        guard case .ioFailure = verdict else {
            Issue.record("Expected direct AVIO seek failure, got \(verdict)")
            return
        }
        #expect(harness.seekCalls >= 1)
    }
}

@Suite(
    "M2TS Dolby Vision scanner AVIO state",
    .enabled(if: ProcessInfo.processInfo.environment["PRISMCORE_DV7_M2TS_FIXTURES"] != nil)
)
struct M2TSDolbyVisionScannerAVIOStateTests {
    @Test("a successful bounded scan restores cursor EOF and error")
    func successfulScanIsObservational() throws {
        let path = try #require(
            ProcessInfo.processInfo.environment["PRISMCORE_DV7_M2TS_FIXTURES"]?
                .split(separator: ":").first
        )
        let guardBox = ReadInterruptGuard()
        var context: UnsafeMutablePointer<AVFormatContext>? = guardBox.makeContext()
        try FFmpegError.check(
            avformat_open_input(&context, String(path), nil, nil),
            "avformat_open_input(M2TS scanner test)"
        )
        defer { avformat_close_input(&context) }
        let input = try #require(context)
        let pb = try #require(input.pointee.pb)
        let size = avio_size(pb)
        #expect(size > 0)
        #expect(avio_seek(pb, size, SEEK_SET) == size)
        var byte: UInt8 = 0
        _ = avio_read(pb, &byte, 1)
        let originalPosition = avio_tell(pb)
        let originalEOF = pb.pointee.eof_reached
        let originalError = pb.pointee.error

        let verdict = M2TSDolbyVisionAssociation.scan(input: input, interruptGuard: guardBox)
        guard case .verdict(.association) = verdict else {
            Issue.record("Expected M2TS association, got \(verdict)")
            return
        }
        #expect(avio_tell(pb) == originalPosition)
        #expect(pb.pointee.eof_reached == originalEOF)
        #expect(pb.pointee.error == originalError)
    }
}

private final class ScannerInput: PrismCoreInput, @unchecked Sendable {
    var length: Int64? { 3840 }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        throw ScannerInputError.read
    }

    func seek(to offset: Int64) throws {}
}

private enum ScannerInputError: Error {
    case read
}

private final class DirectSeekFailureAVIO {
    private(set) var seekCalls = 0

    func install(on context: UnsafeMutablePointer<AVFormatContext>) throws -> UnsafeMutablePointer<AVIOContext> {
        guard let allocation = av_malloc(4096) else {
            throw PrismCoreInputError.allocation
        }
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        guard let io = avio_alloc_context(
            allocation.assumingMemoryBound(to: UInt8.self), 4096, 0, opaque,
            { _, _, _ in swift_AVERROR_EOF() },
            nil,
            { opaque, _, whence in
                guard let opaque else { return Int64(swift_AVERROR(EIO)) }
                let harness = Unmanaged<DirectSeekFailureAVIO>.fromOpaque(opaque).takeUnretainedValue()
                if whence & 0x10000 != 0 { return 3840 } // AVSEEK_SIZE
                harness.seekCalls += 1
                return Int64(swift_AVERROR(EIO))
            }
        ) else {
            av_free(allocation)
            throw PrismCoreInputError.allocation
        }
        io.pointee.seekable = Int32(AVIO_SEEKABLE_NORMAL)
        context.pointee.pb = io
        context.pointee.flags |= 0x0080 // AVFMT_FLAG_CUSTOM_IO
        return io
    }
}
