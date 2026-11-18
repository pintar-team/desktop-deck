import Foundation
import Logging
import MCP

/// Bridges experimental capability values that the pinned SDK cannot decode.
actor CompatibleStdioTransport: Transport {
    private let stdio = StdioTransport()
    private var messages = AsyncThrowingStream<Data, Error> { $0.finish() }

    nonisolated var logger: Logger { stdio.logger }

    func connect() async throws {
        try await stdio.connect()
        let reader = Reader(await stdio.receive())
        messages = AsyncThrowingStream(unfolding: { try await reader.next() })
    }

    func disconnect() async { await stdio.disconnect() }
    func send(_ data: Data) async throws { try await stdio.send(data) }
    func receive() -> AsyncThrowingStream<Data, Error> { messages }

    private actor Reader {
        private var iterator: AsyncThrowingStream<Data, Error>.Iterator

        init(_ stream: AsyncThrowingStream<Data, Error>) {
            iterator = stream.makeAsyncIterator()
        }

        func next() async throws -> Data? {
            // The SDK consumes this stream serially. Keep one iterator and pull
            // each message on demand, without adding a second buffer.
            var cursor = iterator
            let message = try await cursor.next(isolation: self)
            iterator = cursor
            return message.map(Self.normalizeInitialize)
        }

        private static func normalizeInitialize(_ data: Data) -> Data {
            guard var request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  request["method"] as? String == "initialize",
                  var params = request["params"] as? [String: Any],
                  var capabilities = params["capabilities"] as? [String: Any],
                  let experimental = capabilities["experimental"] as? [String: Any]
            else { return data }

            // Desktop Deck does not negotiate experimental extensions. Pass
            // through entries the SDK understands and leave all other fields intact.
            let supported = experimental.compactMapValues { $0 as? String }
            guard supported.count != experimental.count else { return data }
            capabilities["experimental"] = supported
            params["capabilities"] = capabilities
            request["params"] = params
            return (try? JSONSerialization.data(withJSONObject: request)) ?? data
        }
    }
}
