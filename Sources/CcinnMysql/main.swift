// CcinnMysql — a native StarRocks client for macOS.
// `CcinnMysql mcp …` runs the headless MCP server instead of the app.
let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "mcp" {
    MCPCommand.run(arguments: Array(arguments.dropFirst()))
} else {
    CcinnMysqlApp.main()
}
