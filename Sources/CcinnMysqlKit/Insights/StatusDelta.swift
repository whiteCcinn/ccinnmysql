import Foundation
import MySQLKit

/// Per-second rates of `SHOW GLOBAL STATUS` counters between two snapshots, and derived health figures.
public enum StatusMetrics {
    /// Counters (monotonic) only: gauges such as `Threads_connected` are not rates.
    static let gauges: Set<String> = ["threads_connected", "threads_running", "threads_cached", "open_tables", "open_files",
                                      "innodb_buffer_pool_pages_free", "innodb_buffer_pool_pages_total", "innodb_buffer_pool_pages_data",
                                      "innodb_buffer_pool_pages_dirty", "uptime", "uptime_since_flush_status", "max_used_connections",
                                      "innodb_row_lock_current_waits", "slave_open_temp_tables", "replica_open_temp_tables", "open_streams",
                                      "innodb_history_list_length", "wsrep_cluster_size", "wsrep_local_recv_queue", "wsrep_local_send_queue"]

    /// Name → change per second. Counters that went backwards (FLUSH STATUS, restart) or are not numeric are skipped.
    public static func rates(previous: [ServerVariable], current: [ServerVariable], seconds: Double) -> [String: Double] {
        guard seconds.isFinite, seconds > 0 else { return [:] }
        let before = Dictionary(previous.map { ($0.name.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        var rates: [String: Double] = [:]
        for variable in current {
            let key = variable.name.lowercased()
            guard !gauges.contains(key), let old = before[key], let oldValue = Double(old), let newValue = Double(variable.value),
                  oldValue.isFinite, newValue.isFinite, newValue >= oldValue else { continue }
            rates[variable.name] = (newValue - oldValue) / seconds
        }
        return rates
    }

    /// InnoDB buffer pool hit ratio (0…1) from read requests vs. disk reads; `nil` without traffic.
    public static func bufferPoolHitRatio(_ status: [ServerVariable]) -> Double? {
        let values = Dictionary(status.map { ($0.name.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        guard let requests = values["innodb_buffer_pool_read_requests"].flatMap(Double.init), requests > 0,
              let reads = values["innodb_buffer_pool_reads"].flatMap(Double.init), reads >= 0 else { return nil }
        return max(0, min(1, 1 - reads / requests))
    }

    public static func value(_ name: String, in status: [ServerVariable]) -> String? {
        status.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}
