import Foundation

/// Side-by-side placement for overlapping events in a day column, like
/// Calendar's week view: events that overlap split the width, each in the
/// leftmost column free at its start.
public enum TimeGridLayout {
    public struct Placement: Equatable, Sendable {
        public let column: Int
        public let columns: Int
        public init(column: Int, columns: Int) {
            self.column = column
            self.columns = columns
        }
    }

    public static func place(_ events: [AgendaItem]) -> [String: Placement] {
        let sorted = events.sorted { ($0.start, $1.end) < ($1.start, $0.end) }
        var result: [String: Placement] = [:]
        var cluster: [(id: String, column: Int)] = []
        var columnEnds: [Date] = []   // when each column in the cluster frees up
        var clusterEnd = Date.distantPast

        func close() {
            for entry in cluster { result[entry.id] = Placement(column: entry.column, columns: columnEnds.count) }
            cluster = []
            columnEnds = []
        }

        for event in sorted {
            // An event starting after everything so far has ended starts a new cluster.
            if event.start >= clusterEnd { close() }
            if let free = columnEnds.firstIndex(where: { $0 <= event.start }) {
                columnEnds[free] = event.end
                cluster.append((event.id, free))
            } else {
                columnEnds.append(event.end)
                cluster.append((event.id, columnEnds.count - 1))
            }
            clusterEnd = max(clusterEnd, event.end)
        }
        close()
        return result
    }
}
