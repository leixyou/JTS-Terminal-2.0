//
//  OrderedPTYEventBufferTests.swift
//  JTSTerminalTests
//
//  Created by Codex on 2026/7/28.
//

import Testing
@testable import JTSTerminal

struct OrderedPTYEventBufferTests {
    @Test("Exit before output waits for EOF and drains output first")
    func exitBeforeOutput() {
        var buffer = OrderedPTYEventBuffer()
        buffer.recordProcessExit(status: 255 << 8)
        #expect(buffer.drain().isEmpty)

        buffer.appendOutput(Array("Permission denied.\r\n".utf8))
        #expect(buffer.drain() == [
            .output(Array("Permission denied.\r\n".utf8)),
        ])

        buffer.recordReadEOF()
        #expect(buffer.drain() == [.termination(255 << 8)])
        #expect(buffer.drain().isEmpty)
    }

    @Test("Output before exit still terminates only after EOF")
    func outputBeforeExit() {
        var buffer = OrderedPTYEventBuffer()
        buffer.appendOutput([1, 2, 3])
        buffer.recordReadEOF()
        #expect(buffer.drain() == [.output([1, 2, 3])])

        buffer.recordProcessExit(status: 0)
        #expect(buffer.drain() == [.termination(0)])
    }

    @Test("EOF before exit produces one termination")
    func eofBeforeExit() {
        var buffer = OrderedPTYEventBuffer()
        buffer.recordReadEOF()
        #expect(buffer.drain().isEmpty)

        buffer.recordProcessExit(status: nil)
        buffer.recordProcessExit(status: 42)
        buffer.recordReadEOF()
        #expect(buffer.drain() == [.termination(nil)])
        #expect(buffer.drain().isEmpty)
    }

    @Test("A time-sliced drain cannot overtake remaining output")
    func timeSlicedDrain() {
        var buffer = OrderedPTYEventBuffer()
        buffer.appendOutput([1])
        buffer.appendOutput([2])
        buffer.recordProcessExit(status: 0)
        buffer.recordReadEOF()

        #expect(buffer.drain(maximumOutputChunks: 1) == [.output([1])])
        #expect(buffer.needsDrain)
        #expect(buffer.drain(maximumOutputChunks: 1) == [
            .output([2]),
            .termination(0),
        ])
        #expect(!buffer.needsDrain)
    }

    @Test("Cancellation suppresses buffered output and termination")
    func cancellationSuppressesCallbacks() {
        var buffer = OrderedPTYEventBuffer()
        buffer.appendOutput([1, 2, 3])
        buffer.recordProcessExit(status: 0)
        buffer.recordReadEOF()
        buffer.cancel()

        #expect(!buffer.needsDrain)
        #expect(buffer.drain().isEmpty)
    }

    @Test("Cancellation returns only accepted output not yet delivered")
    func cancellationReturnsUndeliveredOutput() {
        var buffer = OrderedPTYEventBuffer()
        buffer.appendOutput([1])
        buffer.appendOutput([2])
        buffer.appendOutput([3])

        #expect(buffer.drain(maximumOutputChunks: 1) == [.output([1])])
        #expect(buffer.cancelAndTakePendingOutput() == [[2], [3]])
        #expect(buffer.cancelAndTakePendingOutput().isEmpty)
        #expect(buffer.drain().isEmpty)
    }
}
