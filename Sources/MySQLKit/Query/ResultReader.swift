import Foundation
import MySQLWire

/// Reads the response to COM_QUERY: OK | ERR | result set(s), honouring `RowLimits`.
enum ResultReader {
    static let serverMoreResultsExists: UInt16 = 0x0008
    static let maxColumns: UInt64 = 16_384

    static func readResults(from channel: inout PacketChannel, capabilities: Capabilities, limits: RowLimits) async throws -> [ResultSet] {
        var results: [ResultSet] = []
        while true {
            let header = try await channel.read()
            guard let first = header.first else {
                throw MySQLError(.protocolViolation, "Empty response packet")
            }
            switch first {
            case 0x00:
                let ok = try ServerPacket.parseOK(header, capabilities: capabilities)
                results.append(ResultSet(ok: ok))
                if !ok.hasMoreResults { return results }
            case 0xFF:
                throw MySQLError.server(try ServerPacket.parseError(header))
            case 0xFB:
                // LOCAL INFILE request: never honoured (CLIENT_LOCAL_FILES is not requested). The protocol
                // cannot continue without sending a file, so the connection is dropped.
                throw MySQLError(.protocolViolation, "The server asked for a local file (LOAD DATA LOCAL INFILE), which CcinnMysql never sends")
            default:
                let (result, status) = try await readRowSet(header: header, from: &channel, capabilities: capabilities, limits: limits)
                results.append(result)
                if channel.isAbandoned || status & serverMoreResultsExists == 0 { return results }
            }
        }
    }

    private static func readRowSet(header: [UInt8], from channel: inout PacketChannel, capabilities: Capabilities,
                                   limits: RowLimits) async throws -> (ResultSet, UInt16) {
        var reader = PayloadReader(header)
        let columnCount = try reader.readLengthEncodedInteger()
        guard columnCount > 0, columnCount <= maxColumns else {
            throw MySQLError(.protocolViolation, "Invalid column count \(columnCount)")
        }
        var columns: [ColumnDefinition] = []
        columns.reserveCapacity(Int(columnCount))
        for _ in 0..<Int(columnCount) {
            columns.append(try ColumnDefinition(payload: try await channel.read()))
        }
        if !capabilities.contains(.deprecateEOF) {
            let eof = try await channel.read()
            guard ServerPacket.isResultTerminator(eof) else {
                throw MySQLError(.protocolViolation, "Missing EOF after column definitions")
            }
        }

        var rows: [[String?]] = []
        var keptBytes = 0
        var discarded = 0
        var truncated = false
        while true {
            let payload = try await channel.read()
            if payload.first == 0xFF {
                throw MySQLError.server(try ServerPacket.parseError(payload))
            }
            if ServerPacket.isResultTerminator(payload) {
                let status = try ServerPacket.terminatorStatus(payload, capabilities: capabilities)
                return (ResultSet(columns: columns, rows: rows, isTruncated: truncated, status: ServerStatus(rawValue: status)), status)
            }
            if !truncated, rows.count < limits.maxRows, keptBytes + payload.count <= limits.maxBytes {
                rows.append(try TextRow.decode(payload, columnCount: columns.count))
                keptBytes += payload.count
                continue
            }
            truncated = true
            discarded += 1
            if discarded > limits.drainRows {
                // Stop reading: the caller drops the connection and kills the server-side query.
                channel.isAbandoned = true
                return (ResultSet(columns: columns, rows: rows, isTruncated: true), 0)
            }
        }
    }
}
