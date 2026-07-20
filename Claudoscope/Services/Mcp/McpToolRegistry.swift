import Foundation
import MCP

/// Builds one MCP.Server per client connection, exposing the read-only
/// claudoscope tool set.
enum McpToolRegistry {
    static let serverName = "claudoscope"

    static func makeServer(context: McpToolContext) async -> MCP.Server {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let server = Server(
            name: serverName,
            version: version,
            instructions: """
            Read-only access to Claudoscope, the local Claude Code observability app. \
            Costs are estimates computed from local transcripts with the same engine as \
            the Claudoscope dashboard. Session tools return transcript_file paths; read \
            those JSONL files directly for full conversation content.
            """,
            capabilities: .init(tools: .init(listChanged: false))
        )
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: toolDefinitions)
        }
        await server.withMethodHandler(CallTool.self) { params in
            await McpToolHandlers.dispatch(name: params.name, arguments: params.arguments, context: context)
        }
        return server
    }

    private static let readOnly = Tool.Annotations(readOnlyHint: true)

    private static let projectProperty: Value = [
        "type": "string",
        "description": "Project filter: display name, encoded project id, or absolute path",
    ]
    private static let dayProperties: [String: Value] = [
        "from": ["type": "string", "description": "Start day, YYYY-MM-DD (inclusive, local time)"],
        "to": ["type": "string", "description": "End day, YYYY-MM-DD (inclusive, local time)"],
    ]
    private static let limitProperty: Value = [
        "type": "integer",
        "description": "Max results (default 25, max 200)",
    ]

    static let toolDefinitions: [Tool] = [
        Tool(
            name: "get_usage",
            description: "Cost and token analytics for Claude Code usage: totals plus per-day, per-model, and per-project breakdowns with cache analytics. Numbers match the Claudoscope dashboard.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "period": [
                        "type": "string",
                        "enum": ["today", "7d", "30d", "all", "custom"],
                        "description": "Time window (default all). custom requires from/to.",
                    ],
                    "from": dayProperties["from"]!,
                    "to": dayProperties["to"]!,
                    "project": projectProperty,
                ],
            ],
            annotations: readOnly
        ),
        Tool(
            name: "list_projects",
            description: "All Claude Code projects with session counts, real filesystem paths, total estimated cost, and last activity.",
            inputSchema: ["type": "object", "properties": [:]],
            annotations: readOnly
        ),
        Tool(
            name: "list_sessions",
            description: "List Claude Code sessions (newest first by default) with cost, tokens, and the transcript JSONL file path.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "project": projectProperty,
                    "from": dayProperties["from"]!,
                    "to": dayProperties["to"]!,
                    "limit": limitProperty,
                    "sort": [
                        "type": "string",
                        "enum": ["last_activity", "cost", "tokens"],
                        "description": "Sort order (default last_activity)",
                    ],
                    "include_subagents": [
                        "type": "boolean",
                        "description": "Include subagent (sidechain) sessions (default false)",
                    ],
                ],
            ],
            annotations: readOnly
        ),
        Tool(
            name: "search_sessions",
            description: "Search sessions by keywords over title, slug, and project name. Returns the same pointer records as list_sessions; read the transcript_file for full content.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Keywords; all terms must match"],
                    "project": projectProperty,
                    "from": dayProperties["from"]!,
                    "to": dayProperties["to"]!,
                    "limit": limitProperty,
                ],
                "required": ["query"],
            ],
            annotations: readOnly
        ),
        Tool(
            name: "get_session",
            description: "Full detail for one session: per-model token/cost breakdown, per-day billed contributions, observability stats, subagent linkage, and transcript file path.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Session id (UUID)"],
                ],
                "required": ["id"],
            ],
            annotations: readOnly
        ),
        Tool(
            name: "lint_config",
            description: "Run a fresh Claudoscope lint of the Claude Code configuration (CLAUDE.md, rules, skills, hooks, settings, secrets in session data) and return findings with a health score. Secret values are always masked.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "project": projectProperty,
                ],
            ],
            annotations: readOnly
        ),
        Tool(
            name: "get_config",
            description: "Inventory of loaded Claude Code configuration: commands, skills, MCP servers, memory files, hooks, and plugins, each with its source level. MCP env values are masked.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "kind": [
                        "type": "string",
                        "enum": ["commands", "skills", "mcp_servers", "memory", "hooks", "plugins"],
                        "description": "Restrict to one kind (default: all)",
                    ],
                    "project": projectProperty,
                ],
            ],
            annotations: readOnly
        ),
        Tool(
            name: "list_plans",
            description: "List saved Claude Code plan files with title, project hint, creation date, and file path (read the file for plan content).",
            inputSchema: [
                "type": "object",
                "properties": [
                    "project": projectProperty,
                    "from": dayProperties["from"]!,
                    "to": dayProperties["to"]!,
                    "limit": limitProperty,
                ],
            ],
            annotations: readOnly
        ),
        Tool(
            name: "get_canon",
            description: "Project canon records (settled engineering decisions in .claude/canon.md). With a project: its records. Without: which projects have a canon.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "project": projectProperty,
                ],
            ],
            annotations: readOnly
        ),
    ]
}
