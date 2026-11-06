#if os(macOS) || os(Linux)
import Foundation
import Dispatch
import XCTest
@testable import FaviconFinder

/// Both real transports talk to two loopback origins. No injected loader and no
/// third-party network site. Image decoding is deliberately outside these tests.
final class FaviconLoopbackTransportTests: XCTestCase {
    func testSameOriginHTTPRedirectCarriesExplicitHeaders() async throws {
        let fixture = try LoopbackFaviconServer()
        defer { fixture.stop() }
        let result = try await FaviconURLSession.documentTask(with: fixture.url("same"), httpHeaders: fixture.headers)
        let echoed = try fixture.echoedHeaders(result.data)
        XCTAssertEqual(echoed["authorization"], "TEST_ONLY")
        XCTAssertEqual(echoed["x-api-key"], "TEST_ONLY")
        XCTAssertEqual(echoed["accept-language"], "ja")
        XCTAssertEqual(result.url, fixture.url("echo"))
    }

    func testCrossOriginHTTPRoundTripDoesNotRestoreCredentials() async throws {
        let fixture = try LoopbackFaviconServer()
        defer { fixture.stop() }
        let result = try await FaviconURLSession.documentTask(with: fixture.url("cross"), httpHeaders: fixture.headers)
        let echoed = try fixture.echoedHeaders(result.data)
        XCTAssertNil(echoed["authorization"])
        XCTAssertNil(echoed["cookie"])
        XCTAssertNil(echoed["x-api-key"])
        XCTAssertEqual(echoed["accept-language"], "ja")
        XCTAssertEqual(result.url, fixture.url("echo"))
        XCTAssertEqual(result.httpHeaders, ["Accept-Language": "ja"])
    }

    func testMetaRefreshUsesTheSameRealTransportPolicy() async throws {
        let fixture = try LoopbackFaviconServer()
        defer { fixture.stop() }
        let result = try await FaviconURLSession.documentTask(with: fixture.url("meta"),
            checkForMetaRefreshRedirect: true, httpHeaders: fixture.headers)
        let echoed = try fixture.echoedHeaders(result.data)
        XCTAssertNil(echoed["authorization"])
        XCTAssertNil(echoed["x-api-key"])
        XCTAssertEqual(echoed["accept-language"], "ja")
        XCTAssertNotEqual(result.url.port, fixture.url("echo").port)
    }

    func testActualBackendRejectsHTTPErrorPageWithIconMetadata() async throws {
        let fixture = try LoopbackFaviconServer()
        defer { fixture.stop() }
        do {
            _ = try await FaviconFinder(url: fixture.url("error"),
                configuration: .init(preferredSource: .html)
            ).fetchFaviconURLs()
            XCTFail("An error page icon must not be reported as the site's favicon")
        } catch {
            guard case FaviconError.failedToFindFavicon = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testActualBackendEnforcesTheSharedRedirectBudget() async throws {
        let fixture = try LoopbackFaviconServer()
        defer { fixture.stop() }
        do {
            _ = try await FaviconURLSession.documentTask(with: fixture.url("loop"))
            XCTFail("Expected redirect rejection")
        } catch { XCTAssertEqual((error as? URLError)?.code, .httpTooManyRedirects) }
    }

    func testRealStreamAcceptsExactLimitAndRejectsAnExtraByte() async throws {
        let fixture = try LoopbackFaviconServer()
        defer { fixture.stop() }
        let limit = FaviconRequestPolicy.maximumResponseBytes
        let result = try await FaviconURLSession.dataTask(with: fixture.url("body/\(limit)"))
        XCTAssertEqual(result.data.count, limit)
        do {
            _ = try await FaviconURLSession.dataTask(with: fixture.url("body/\(limit + 1)"))
            XCTFail("Expected bounded collection to reject excess data")
        } catch {
            // AsyncHTTPClient and URLSession expose different typed size errors.
            XCTAssertFalse(error is CancellationError)
        }
    }

    func testCancellationDuringActualNetworkWaitDoesNotPublishSuccess() async throws {
        let fixture = try LoopbackFaviconServer()
        defer { fixture.stop() }
        let url = fixture.url("slow")
        let task = Task {
            try await FaviconURLSession.dataTask(with: url)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
}

private final class LoopbackFaviconServer {
    private let process = Process()
    private let output = Pipe()
    private let input = Pipe()
    private let terminated = DispatchSemaphore(value: 0)
    private var stopped = false
    private let port: Int
    let headers: [String: String?] = ["Authorization": "TEST_ONLY", "Cookie": "TEST_ONLY",
                                     "X-Api-Key": "TEST_ONLY", "Accept-Language": "ja"]

    init() throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-u", "-c", Self.program]
        process.standardOutput = output
        process.standardInput = input
        let terminated = self.terminated
        process.terminationHandler = { _ in terminated.signal() }
        try process.run()
        // The child emits one small JSON startup record. EOF on startup failure
        // throws rather than selecting a guessed/fixed port.
        let data = output.fileHandleForReading.availableData
        guard let record = try JSONSerialization.jsonObject(with: data) as? [String: Int],
              let port = record["port"] else {
            process.terminate()
            throw URLError(.cannotConnectToHost)
        }
        self.port = port
    }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)/\(path)")! }
    func echoedHeaders(_ data: Data) throws -> [String: String] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
    }
    func stop() {
        guard !stopped else { return }
        stopped = true
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        // Foundation's run-loop-based waitUntilExit can stall on a cooperative
        // executor even after the child exits. Join the registered exit event;
        // deinit must not consume that one-shot notification a second time.
        if terminated.wait(timeout: .now() + 5) == .timedOut {
            XCTFail("Loopback fixture did not terminate within five seconds")
            terminated.wait() // Keep ownership until actual child termination.
        }
    }
    deinit { stop() }

    private static let program = #"""
import http.server, json, threading, sys, time
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args): pass
    def do_GET(self):
        try: self.respond()
        except (BrokenPipeError, ConnectionResetError): pass
    def respond(self):
        path = self.path
        if path in ['/error', '/favicon.ico']:
            body = b"<head><link rel='icon' href='/error-icon.png'></head>"
            self.send_response(404); self.send_header('Content-Type','text/html; charset=utf-8')
            self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body); return
        if path in ['/same', '/cross', '/return', '/loop']:
            target = {'/same':'/echo', '/cross':f'http://127.0.0.1:{second.server_port}/return',
                      '/return':f'http://127.0.0.1:{first.server_port}/echo', '/loop':'/loop'}[path]
            self.send_response(302); self.send_header('Location', target)
            self.send_header('Content-Length','0'); self.end_headers(); return
        if path == '/meta':
            body = f'<head><meta http-equiv="refresh" content="0; URL=http://127.0.0.1:{second.server_port}/echo"></head>'.encode()
        elif path.startswith('/body/'):
            size = int(path.split('/')[-1])
            self.send_response(200); self.send_header('Content-Type','application/octet-stream')
            self.send_header('Content-Length',str(size)); self.end_headers()
            while size:
                chunk = min(size, 4096); self.wfile.write(b'x'*chunk); self.wfile.flush(); size -= chunk
            return
        elif path == '/slow':
            self.send_response(200); self.send_header('Content-Length','1'); self.end_headers()
            time.sleep(2); self.wfile.write(b'x'); return
        else: body = json.dumps({key.lower():value for key,value in self.headers.items()}).encode()
        self.send_response(200); self.send_header('Content-Type','text/html; charset=utf-8')
        self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body)
first = http.server.ThreadingHTTPServer(('127.0.0.1',0), Handler)
second = http.server.ThreadingHTTPServer(('127.0.0.1',0), Handler)
for server in (first,second): threading.Thread(target=server.serve_forever,daemon=True).start()
print(json.dumps({'port':first.server_port}),flush=True)
sys.stdin.buffer.read()
"""#
}
#endif

