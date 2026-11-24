import AppKit
import MySQLWire
import Testing
@testable import CcinnMysql

/// The grid sorts on the server when its owner pages there, the Data tab (add-data-paging-and-sort).
@Suite("Result grid sorting", .serialized)
@MainActor
struct ResultGridSortTests {
    static let columns = [ColumnDefinition(name: "id", type: .longLong), ColumnDefinition(name: "city", type: .varString)]
    static let rows: [[String?]] = [["3", "KL"], ["1", "Penang"], ["2", "Ipoh"]]

    private func makeGrid(serverSort: ResultGrid.ServerSort?, rowNumberOffset: Int = 0) -> (ResultGrid.Coordinator, NSTableView) {
        let grid = ResultGrid(resultID: UUID(), columns: Self.columns, rows: Self.rows, serverSort: serverSort, rowNumberOffset: rowNumberOffset)
        let coordinator = ResultGrid.Coordinator(grid)
        let tableView = NSTableView()
        coordinator.tableView = tableView
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        coordinator.load(grid)
        return (coordinator, tableView)
    }

    private func displayedIDs(_ coordinator: ResultGrid.Coordinator) -> [String?] {
        (0..<Self.rows.count).map { Self.rows[coordinator.rowIndex($0)][0] }
    }

    @Test func headerClicksAskTheServerAndTheThirdClickClears() async throws {
        var requests: [ResultGrid.SortRequest?] = []
        let (coordinator, tableView) = makeGrid(serverSort: .init(column: nil, ascending: true, onChange: { requests.append($0) }))
        tableView.sortDescriptors = [NSSortDescriptor(key: "1", ascending: true)]
        tableView.sortDescriptors = [NSSortDescriptor(key: "1", ascending: false)]
        tableView.sortDescriptors = [NSSortDescriptor(key: "1", ascending: true)]
        #expect(requests == [.init(column: 1, ascending: true), .init(column: 1, ascending: false), nil])
        #expect(tableView.sortDescriptors.isEmpty, "the arrow goes away with the sort")
        try await Task.sleep(for: .milliseconds(100))
        #expect(displayedIDs(coordinator) == ["3", "1", "2"], "the rows stay as the server sent them")
    }

    @Test func theServerSortShowsAsTheHeaderArrow() {
        var requests: [ResultGrid.SortRequest?] = []
        let (_, tableView) = makeGrid(serverSort: .init(column: 0, ascending: false, onChange: { requests.append($0) }))
        #expect(tableView.sortDescriptors.first?.key == "0")
        #expect(tableView.sortDescriptors.first?.ascending == false)
        #expect(requests.isEmpty, "showing the server's sort is not a new request")
    }

    @Test func withoutAServerTheGridSortsItsOwnRows() async throws {
        let (coordinator, tableView) = makeGrid(serverSort: nil)
        tableView.sortDescriptors = [NSSortDescriptor(key: "0", ascending: true)]
        let deadline = ContinuousClock.now + .seconds(2)
        while displayedIDs(coordinator) != ["1", "2", "3"], ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(displayedIDs(coordinator) == ["1", "2", "3"])
    }

    @Test func rowNumbersCountFromThePagesFirstRow() throws {
        let (coordinator, tableView) = makeGrid(serverSort: nil, rowNumberOffset: 200)
        let numberColumn = try #require(tableView.tableColumns.first)
        let cell = coordinator.tableView(tableView, viewFor: numberColumn, row: 0) as? NSTableCellView
        #expect(cell?.textField?.stringValue == "201")
    }
}
