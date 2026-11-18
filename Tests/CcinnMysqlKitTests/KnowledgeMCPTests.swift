import Foundation
import os
import Testing
@testable import CcinnMysqlKit
import MySQLKit

@Suite("Knowledge MCP tools")
struct KnowledgeMCPToolTests {
    static let prod = ConnectionProfile(name: "Prod", host: "prod", mcpAccess: .readOnly)
    static let off = ConnectionProfile(name: "Off", host: "off", mcpAccess: .disabled)

    /// Tools over `bed`'s store; every connection attempt is counted and fails.
    final class Harness: @unchecked Sendable {
        let bed: KnowledgeFixture.Testbed
        let opens = OSAllocatedUnfairLock(initialState: 0)
        let tools: KnowledgeMCPTools
        let audit: MCPAuditLog

        init(bed: KnowledgeFixture.Testbed, profiles: [ConnectionProfile]) {
            self.bed = bed
            let opens = opens
            let registry = MCPClientRegistry { _ in
                opens.withLock { $0 += 1 }
                throw MySQLError(.network, "no server in unit tests")
            }
            audit = MCPAuditLog(directory: bed.data.url)
            tools = KnowledgeMCPTools(resolver: MCPProfileResolver(profiles: profiles, defaultProfile: nil, forceReadOnly: false),
                                      registry: registry, store: bed.store, audit: audit)
        }

        func call(_ name: String, _ arguments: [String: JSONValue]) async -> MCPToolResult {
            await tools.call(name: name, arguments: arguments)
        }
    }

    /// A built knowledge base of `prod`'s `ads` database.
    private func harness(profiles: [ConnectionProfile] = [prod, off]) async throws -> Harness {
        let bed = KnowledgeFixture.Testbed(connectionID: Self.prod.id)
        try bed.code.write("report/dsp.go", KnowledgeFixture.goSource)
        let path = bed.code.url.path
        try await bed.store.update(bed.key) { kb in kb.projects = [LinkedProject(name: "report-svc", path: path)] }
        _ = try await KnowledgeBuilder(store: bed.store).build(bed.key, source: FakeSchemaSource(schema: KnowledgeFixture.facts()))
        return Harness(bed: bed, profiles: profiles)
    }

    @Test func toolsAreStrictAndOnlyBuildAndAnnotateWrite() async throws {
        let harness = try await harness()
        let tools = await harness.tools.tools()
        #expect(tools.map(\.name) == ["knowledge_status", "knowledge_build", "knowledge_search", "knowledge_context", "knowledge_join_path",
                                      "knowledge_erd", "knowledge_annotate"])
        for tool in tools {
            #expect(tool.inputSchema["additionalProperties"] == .bool(false), "\(tool.name)")
            #expect(tool.readOnly == !["knowledge_build", "knowledge_annotate"].contains(tool.name), "\(tool.name)")
            #expect(!tool.destructive, "\(tool.name)")
        }
        let unknown = await harness.call("knowledge_search", ["database": "ads", "query": "dsp", "sql": "SELECT 1"])
        #expect(unknown.isError && unknown.payload.stringValue?.contains("`sql`") == true)
    }

    @Test func queriesWorkOfflineAndNeverConnect() async throws {
        let harness = try await harness()
        let status = await harness.call("knowledge_status", [:])
        #expect(!status.isError)
        #expect(status.payload["knowledge_bases"]?[0]?["database"] == "ads")
        let detail = await harness.call("knowledge_status", ["database": "ADS"])
        #expect(detail.payload["tables"] == 6 && detail.payload["projects"]?[0]?["name"] == "report-svc")
        #expect(detail.payload["relationships_by_source"]?["declared"] == 1)

        let search = await harness.call("knowledge_search", ["database": "ads", "query": "dsp 名称"])
        #expect(search.payload["tables"]?[0]?["table"] == "dsp")

        let context = await harness.call("knowledge_context", ["database": "ads", "tables": ["impressions", "nope"]])
        let impressions = try #require(context.payload["tables"]?[0])
        #expect(impressions["columns"]?.arrayValue?.count == 4)
        #expect(impressions["relationships"]?.arrayValue?.contains { $0["table"] == "dsp" && $0["join"] == "impressions.dsp_id = dsp.dsp_id" } == true)
        #expect(impressions["code_references"]?[0]?["path"] == "report/dsp.go")
        #expect(context.payload["unknown"]?[0]?["name"] == "nope")

        let path = await harness.call("knowledge_join_path", ["database": "ads", "from": "impressions", "to": "advertisers"])
        #expect(path.payload["paths"]?[0]?["sql"]?.stringValue?.contains("JOIN advertisers ON advertisers.id = campaigns.advertiser_id") == true)
        let none = await harness.call("knowledge_join_path", ["database": "ads", "from": "impressions", "to": "customers"])
        #expect(none.payload["paths"]?.arrayValue?.isEmpty == true && none.payload["hint"] != nil)

        let erd = await harness.call("knowledge_erd", ["database": "ads", "tables": ["campaigns"]])
        #expect(erd.payload["mermaid"]?.stringValue?.hasPrefix("erDiagram") == true)
        #expect(harness.opens.withLock { $0 } == 0, "offline tools never open a connection")
    }

    @Test func disabledConnectionsRevealNothing() async throws {
        let harness = try await harness()
        let calls: [(String, [String: JSONValue])] = [
            ("knowledge_status", ["connection": "Off", "database": "ads"]),
            ("knowledge_search", ["connection": "Off", "database": "ads", "query": "x"]),
            ("knowledge_annotate", ["connection": "Off", "database": "ads", "table_notes": [["table": "dsp", "summary": "x"]]]),
        ]
        for (name, arguments) in calls {
            let result = await harness.call(name, arguments)
            #expect(result.isError && result.payload.stringValue?.contains("does not allow AI access") == true, "\(name)")
        }
    }

    @Test func annotationsRoundTripThroughTheTools() async throws {
        let harness = try await harness()
        let annotated = await harness.call("knowledge_annotate", [
            "database": "ads",
            "column_notes": [["table": "campaigns", "column": "status", "note": "Delivery state", "values": ["1": "active", "2": "paused", "3": 3]]],
            "glossary": [["term": "spend", "definition": "Cost paid to DSPs", "tables": ["impressions"], "sql": "SELECT SUM(cost) FROM impressions"]],
            "verdicts": [["from_table": "campaigns", "from_columns": ["advertiser_id"], "to_table": "advertisers", "to_columns": ["id"], "verdict": "confirmed"]],
        ])
        #expect(!annotated.isError, "\(annotated.payload)")
        #expect(annotated.payload["applied"]?.arrayValue?.count == 3)
        let search = await harness.call("knowledge_search", ["database": "ads", "query": "paused"])
        #expect(search.payload["tables"]?[0]?["table"] == "campaigns")
        let glossary = await harness.call("knowledge_search", ["database": "ads", "query": "spend"])
        #expect(glossary.payload["glossary"]?[0]?["sql"] == "SELECT SUM(cost) FROM impressions")
        let context = await harness.call("knowledge_context", ["database": "ads", "tables": ["campaigns"]])
        #expect(context.payload["notice"] != nil, "AI notes are flagged as hints")
        let edge = context.payload["tables"]?[0]?["relationships"]?.arrayValue?.first { $0["table"] == "advertisers" }
        #expect(edge?["verdict"] == "confirmed by ai" && edge?["confidence"] == .double(0.95))

        let strict = await harness.call("knowledge_annotate", ["database": "ads", "table_notes": [["table": "dsp", "summary": "x", "author": "user"]]])
        #expect(strict.isError && strict.payload.stringValue?.contains("`author`") == true, "an AI cannot claim to be the user")
        let escape = await harness.call("knowledge_annotate", [
            "database": "ads",
            "relationships": [["from_table": "impressions", "from_columns": ["id"], "to_table": "dsp", "to_columns": ["dsp_id"],
                               "evidence": [["path": "/etc/hosts", "line": 1]]]],
        ])
        #expect(escape.isError)
        let empty = await harness.call("knowledge_annotate", ["database": "ads"])
        #expect(empty.isError)
    }

    @Test func missingKnowledgeAndBuildFailuresAreResults() async throws {
        let harness = try await harness()
        let missing = await harness.call("knowledge_search", ["database": "other", "query": "x"])
        #expect(missing.isError && missing.payload.stringValue?.contains("knowledge_build") == true)
        #expect(missing.payload.stringValue?.contains("ads") == true, "lists the knowledge bases that exist")
        let build = await harness.call("knowledge_build", ["database": "ads"])
        #expect(build.isError && build.payload.stringValue?.contains("no server") == true)
        #expect(harness.opens.withLock { $0 } == 1)
        let log = try String(contentsOf: harness.audit.fileURL, encoding: .utf8)
        #expect(log.contains("\"tool\":\"knowledge_build\"") && log.contains("\"tool\":\"knowledge_search\""))
    }

    @Test func compositeProviderRoutesByToolName() async throws {
        let harness = try await harness()
        let mysql = MySQLMCPTools(resolver: MCPProfileResolver(profiles: [Self.prod], defaultProfile: nil, forceReadOnly: false),
                                  registry: MCPClientRegistry { _ in throw MySQLError(.network, "offline") }, audit: nil)
        let composite = CompositeMCPToolProvider([mysql, harness.tools])
        let names = await composite.tools().map(\.name)
        #expect(names.contains("run_query") && names.contains("knowledge_search"))
        #expect(Set(names).count == names.count, "no duplicate tool names")
        let search = await composite.call(name: "knowledge_search", arguments: ["database": "ads", "query": "dsp"])
        #expect(!search.isError)
        let unknown = await composite.call(name: "nope", arguments: [:])
        #expect(unknown.isError)
    }
}
