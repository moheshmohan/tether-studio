import XCTest
@testable import TetherStudio

final class McpTests: XCTestCase {
    func testARequestIsReadOnlyOnceItIsAllIn() {
        let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        let text = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: \(body.utf8.count)\r\nAuthorization: Bearer abc\r\n\r\n\(body)NEXT"
        let data = Data(text.utf8)
        XCTAssertNil(HttpRequest.parse(data.prefix(30)))
        XCTAssertNil(HttpRequest.parse(data.prefix(data.count - 10)), "body not all in yet")
        let req = HttpRequest.parse(data)
        XCTAssertEqual(req?.method, "POST")
        XCTAssertEqual(req?.path, "/mcp")
        XCTAssertEqual(req?.headers["authorization"], "Bearer abc")
        XCTAssertEqual(req.map { String(data: $0.body, encoding: .utf8) }, body)
        XCTAssertEqual(req.map { String(data: $0.rest, encoding: .utf8) }, "NEXT")
    }

    func testOnlyTheRightTokenAndPagesFromThisMacGetIn() {
        XCTAssertTrue(McpServer.authorized("Bearer secret-token", token: "secret-token"))
        XCTAssertTrue(McpServer.authorized("bearer secret-token", token: "secret-token"))
        XCTAssertFalse(McpServer.authorized("Bearer secret-tokeN", token: "secret-token"))
        XCTAssertFalse(McpServer.authorized("secret-token", token: "secret-token"))
        XCTAssertFalse(McpServer.authorized(nil, token: "secret-token"))
        XCTAssertTrue(McpServer.originAllowed("http://localhost:3000"))
        XCTAssertTrue(McpServer.originAllowed("http://127.0.0.1"))
        XCTAssertFalse(McpServer.originAllowed("https://example.com"))
        XCTAssertFalse(McpServer.originAllowed("http://localhost.example.com"))
        XCTAssertFalse(McpServer.originAllowed("null"))
    }

    func testTheHandshakeAndTheToolList() async {
        let server = McpServer()
        server.tools = { [["name": "get_status"]] }
        let hello = await server.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                         "params": ["protocolVersion": "2025-03-26", "capabilities": [:]]])
        let result = hello?["result"] as? [String: Any]
        XCTAssertEqual(result?["protocolVersion"] as? String, "2025-03-26")
        XCTAssertEqual((result?["serverInfo"] as? [String: Any])?["name"] as? String, "tether-studio")
        let odd = await server.handle(["jsonrpc": "2.0", "id": 2, "method": "initialize", "params": ["protocolVersion": "1999-01-01"]])
        XCTAssertEqual((odd?["result"] as? [String: Any])?["protocolVersion"] as? String, McpServer.protocolVersions[0])
        let note = await server.handle(["jsonrpc": "2.0", "method": "notifications/initialized"])
        XCTAssertNil(note, "a notification gets no reply")
        let list = await server.handle(["jsonrpc": "2.0", "id": 3, "method": "tools/list"])
        XCTAssertEqual(((list?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.count, 1)
        let nope = await server.handle(["jsonrpc": "2.0", "id": 4, "method": "resources/list"])
        XCTAssertEqual((nope?["error"] as? [String: Any])?["code"] as? Int, -32601)
        let unknown = await server.handle(["jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": ["name": "x"]])
        XCTAssertNotNil(unknown?["error"], "no handler yet")
    }

    @MainActor
    func testEveryToolIsListedOnceWithASchema() {
        let tools = McpTools.listing()
        let names = tools.compactMap { $0["name"] as? String }
        XCTAssertEqual(names.count, Set(names).count)
        XCTAssertGreaterThanOrEqual(names.count, 35)
        XCTAssertTrue(names.contains("set_up_board"))
        for want in ["get_status", "list_settings", "set_setting", "start_recording", "stop_recording", "take_photo",
                     "start_timelapse", "stop_timelapse", "apply_preset", "save_preset", "list_clips", "copy_clips",
                     "get_live_view_image", "set_camera_clock", "zoom", "touch_focus", "erase_card", "set_app_option"] {
            XCTAssertTrue(names.contains(want), want)
        }
        for tool in tools {
            let schema = tool["inputSchema"] as? [String: Any]
            XCTAssertEqual(schema?["type"] as? String, "object", "\(tool["name"] ?? "")")
            XCTAssertNotNil(try? JSONSerialization.data(withJSONObject: tool), "\(tool["name"] ?? "") must be JSON")
        }
        let erase = tools.first { $0["name"] as? String == "erase_card" }
        XCTAssertEqual((erase?["annotations"] as? [String: Any])?["destructiveHint"] as? Bool, true)
    }

    func testSettingsMovedByTheirOwnToolsAreNotOpenToSetSetting() async {
        let leaves = await McpTools.actionLeaves
        for leaf in ["movie", "autofocus", "manualfocus", CameraClock.setting] { XCTAssertTrue(leaves.contains(leaf), leaf) }
        XCTAssertFalse(WritableConfig.allowed.contains("d2ca"), "the camera's format control is never written")
        XCTAssertFalse(WritableConfig.allowed.contains("opcode"))
    }
}
