import XCTest
@testable import VaultSquire

/// The gate's contract: strictly one operation at a time, in submission
/// order, and a cancelled waiter never wedges the queue behind it.
final class SerialOperationGateTests: XCTestCase {
    func testOperationsRunOneAtATimeInOrder() async {
        let gate = SerialOperationGate()
        let order = OrderRecorder()

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    await gate.run {
                        await order.record(index)
                        // Yield inside the critical section; a re-entrant gate
                        // would let another operation interleave here.
                        await Task.yield()
                        await order.record(index)
                    }
                }
            }
        }

        let recorded = await order.values
        XCTAssertEqual(recorded.count, 40)
        // Each operation's two records must be adjacent — no interleaving —
        // whatever order the group's tasks reached the gate in.
        var seen = Set<Int>()
        for pair in stride(from: 0, to: recorded.count, by: 2) {
            XCTAssertEqual(
                recorded[pair], recorded[pair + 1],
                "a re-entrant gate would interleave another operation here"
            )
            seen.insert(recorded[pair])
        }
        XCTAssertEqual(seen, Set(0..<20))
    }

    func testACancelledWaiterStillRunsAndDoesNotWedgeTheQueue() async {
        let gate = SerialOperationGate()
        let order = OrderRecorder()

        let first = Task {
            await gate.run {
                await order.record(1)
            }
        }
        first.cancel()
        await first.value

        await gate.run {
            await order.record(2)
        }

        let recorded = await order.values
        XCTAssertEqual(recorded, [1, 2], "a cancelled operation completes its turn; the next still runs")
    }

    private actor OrderRecorder {
        private(set) var values: [Int] = []
        func record(_ value: Int) {
            values.append(value)
        }
    }
}
