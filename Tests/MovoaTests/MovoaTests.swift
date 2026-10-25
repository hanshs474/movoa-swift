import XCTest
@testable import Movoa

/// Answers every request from `MockURL.answer` and records what was sent.
final class MockURL: URLProtocol {
    static var answer: (String) -> (Int, Any) = { _ in (500, [:]) }
    static var sent: [(path: String, body: [String: Any], auth: String?)] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let s = request.httpBodyStream {
            s.open(); defer { s.close() }
            var buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
        }
        let path = request.url!.path
        MockURL.sent.append((path, (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:],
                             request.value(forHTTPHeaderField: "authorization")))
        let (status, body) = MockURL.answer(path)
        let bytes = body is String ? Data((body as! String).utf8) : try! JSONSerialization.data(withJSONObject: body)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class MovoaTests: XCTestCase {
    func client() -> Movoa {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURL.self]
        var m = Movoa(apiKey: "sk-test", baseURL: URL(string: "https://t/")!, session: URLSession(configuration: cfg))
        m.pollInterval = 0
        return m
    }

    func ok(_ data: [String: Any]) -> (Int, Any) { (200, ["code": 0, "message": "ok", "data": data]) }

    override func setUp() { MockURL.sent = [] }

    func testTextToVideoWaitsThroughTheQueue() async throws {
        var polls = 0
        MockURL.answer = { path in
            if path == "/api/ai/generate" { return self.ok(["id": "t1", "status": "pending"]) }
            polls += 1
            return polls == 1 ? self.ok(["id": "t1", "status": "processing", "queued": true, "queueEta": 60])
                : self.ok(["id": "t1", "status": "success", "videos": ["https://cdn.movoa.ai/v.mp4"]])
        }
        let url = try await client().generateVideo("a fox in snow")
        XCTAssertEqual(url.absoluteString, "https://cdn.movoa.ai/v.mp4")
        XCTAssertEqual(MockURL.sent[0].path, "/api/ai/generate")
        XCTAssertEqual(MockURL.sent[0].auth, "Bearer sk-test")
        XCTAssertEqual(MockURL.sent[0].body as NSDictionary, [
            "provider": "auto", "mediaType": "video", "model": "minimax-h3", "scene": "text-to-video",
            "prompt": "a fox in snow", "options": ["sound": true],
        ] as NSDictionary)
        XCTAssertEqual(MockURL.sent[1].path, "/api/ai/query")
        XCTAssertEqual(MockURL.sent[1].body["taskId"] as? String, "t1")
        XCTAssertEqual(MockURL.sent.count, 3)
    }

    func testImageURLSwitchesToImageToVideo() {
        let b = Movoa.submitBody("the statue turns", model: "seedance-2-5", imageURL: "https://x/y.jpg", options: ["duration": 10])
        XCTAssertEqual(b["scene"] as? String, "image-to-video")
        XCTAssertEqual(b["options"] as? NSDictionary, ["duration": 10, "sound": true, "image_input": ["https://x/y.jpg"]] as NSDictionary)
    }

    func testStatusAndCredits() async throws {
        MockURL.answer = { _ in self.ok(["id": "t3", "status": "processing", "queued": true, "queueEta": 120]) }
        let st = try await client().status("t3")
        XCTAssertEqual(st.id, "t3"); XCTAssertTrue(st.queued); XCTAssertEqual(st.queueEta, 120); XCTAssertNil(st.videoURL)
        MockURL.answer = { _ in self.ok(["remainingCredits": 42]) }
        let left = try await client().credits()
        XCTAssertEqual(left, 42)
    }

    func testFailedAndCanceled() async {
        MockURL.answer = { _ in self.ok(["id": "t4", "status": "failed", "errorMessage": "provider down", "failureKind": "upstream"]) }
        do { _ = try await client().wait("t4"); XCTFail("expected failure") } catch let e as Movoa.MovoaError {
            XCTAssertEqual(e, .generation(taskId: "t4", message: "run t4 failed: provider down", errorMessage: "provider down", failureKind: "upstream"))
        } catch { XCTFail("\(error)") }
        MockURL.answer = { _ in self.ok(["id": "t5", "status": "canceled"]) }
        do { _ = try await client().wait("t5"); XCTFail("expected failure") } catch let e as Movoa.MovoaError {
            guard case .generation(let id, _, _, _) = e else { return XCTFail("\(e)") }
            XCTAssertEqual(id, "t5")
        } catch { XCTFail("\(error)") }
    }

    func testTimeoutCarriesTheTaskId() async {
        MockURL.answer = { _ in self.ok(["id": "t6", "status": "processing", "queued": true, "queueEta": 60]) }
        var m = client(); m.timeout = 0; m.pollInterval = 0.005
        do { _ = try await m.wait("t6"); XCTFail("expected timeout") } catch let e as Movoa.MovoaError {
            XCTAssertEqual(e, .timeout(taskId: "t6"))
        } catch { XCTFail("\(error)") }
    }

    func testErrorMapping() {
        func err(_ status: Int, _ body: Any?) -> Movoa.MovoaError? {
            do { _ = try Movoa.check(status, body); return nil } catch { return error as? Movoa.MovoaError }
        }
        XCTAssertEqual(err(401, ["code": -1, "message": "Invalid API key. Create one at https://movoa.ai/settings/apikeys", "data": ["reason": "invalid_api_key"]]),
                       .auth("Invalid API key. Create one at https://movoa.ai/settings/apikeys"))
        XCTAssertEqual(err(200, ["code": -1, "message": "insufficient credits", "data": ["reason": "insufficient_credits"]]), .quota("insufficient credits"))
        XCTAssertEqual(err(200, ["code": -1, "message": "needs a plan", "data": ["reason": "plan_required"]]), .plan("needs a plan"))
        XCTAssertEqual(err(200, ["code": -1, "message": "busy", "data": ["reason": "concurrency"]]), .busy("busy"))
        XCTAssertEqual(err(200, ["code": -2, "message": "blocked"]), .rejected("blocked"))
        XCTAssertEqual(err(200, ["code": -3, "message": "cooldown"]), .rejected("cooldown"))
        XCTAssertEqual(err(200, ["code": -1, "message": "generation failed, please try again"]), .api(status: 200, message: "generation failed, please try again"))
        XCTAssertEqual(err(502, nil), .api(status: 502, message: "movoa.ai returned a non-JSON response"))
        guard case .auth(let m)? = err(200, ["code": -1, "message": "no auth, please sign in"]) else { return XCTFail("no auth") }
        XCTAssertTrue(m.contains("/settings/apikeys"))
    }

    func testNonJSONOverTheWire() async {
        MockURL.answer = { _ in (502, "<html>bad gateway</html>") }
        do { _ = try await client().submit("x"); XCTFail("expected error") } catch let e as Movoa.MovoaError {
            XCTAssertEqual(e, .api(status: 502, message: "movoa.ai returned a non-JSON response"))
        } catch { XCTFail("\(error)") }
    }

    func testMissingKeyFailsBeforeNetwork() async {
        do { _ = try await Movoa(apiKey: "", session: client().session).credits(); XCTFail("expected auth error") }
        catch let e as Movoa.MovoaError { if case .auth = e {} else { XCTFail("\(e)") } }
        catch { XCTFail("\(error)") }
        XCTAssertTrue(MockURL.sent.isEmpty)
    }
}
