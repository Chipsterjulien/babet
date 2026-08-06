return function(test, context)
    local _ENV = test:environment(context)
print("")
print("=== http ===")

do
    local H = babet.http

    -- --- contrat d'erreur : AUCUNE dépendance externe, toujours joué --

    -- request(non-table) lève toujours via luaL_checktype dans
    -- lua_http_request (avant http_perform).
    ok("request(non-table) raises",
        pcall(function() return H.request("not a table") end) == false)
    ok("DOC 4 get rejects non-string URL",
        pcall(function() return H.get(42) end) == false)
    ok("DOC 4 get rejects non-table opts",
        pcall(function() return H.get("http://127.0.0.1/", "bad") end) == false)
    ok("DOC 4 post rejects non-string body",
        pcall(function()
            return H.post("http://127.0.0.1/", 42)
        end) == false)

    -- --- download(): signature and pre-network validation -----------
    ok("HTTP download is exposed",
        type(H.download) == "function")
    ok("HTTP download requires URL and destination",
        pcall(function() return H.download() end) == false)
    ok("HTTP download rejects a missing destination",
        pcall(function() return H.download("http://127.0.0.1/") end) == false)
    ok("HTTP download URL is a strict string",
        pcall(function() return H.download(42, "out.bin") end) == false)
    ok("HTTP download destination is a strict string",
        pcall(function()
            return H.download("http://127.0.0.1/", 42)
        end) == false)
    ok("HTTP download opts must be a table",
        pcall(function()
            return H.download("http://127.0.0.1/", "out.bin", "bad")
        end) == false)
    ok("HTTP download rejects extra arguments",
        pcall(function()
            return H.download("http://127.0.0.1/", "out.bin", {}, true)
        end) == false)
    ok("HTTP download rejects NUL in destination",
        pcall(function()
            return H.download("http://127.0.0.1/", "out\0ignored")
        end) == false)

    do
        local validation_path = "_babet_http_download_validation.tmp"
        babet.remove(validation_path)

        local v, e = H.download("http://127.0.0.1:1/", validation_path, {
            max_file_size = "1024",
        })
        ok_fail("HTTP download max_file_size is a strict integer", v, e)

        v, e = H.download("http://127.0.0.1:1/", validation_path, {
            max_file_size = 0,
        })
        ok_fail("HTTP download rejects max_file_size <= 0", v, e)

        v, e = H.download("http://127.0.0.1:1/", validation_path, {
            max_file_size = 1.5,
        })
        ok_fail("HTTP download rejects fractional max_file_size", v, e)

        v, e = H.download("http://127.0.0.1:1/", validation_path, {
            body = "not allowed on GET",
        })
        ok_fail("HTTP download rejects a request body", v, e)

        v, e = H.download("http://127.0.0.1:1/",
            "_babet_missing_download_parent/out.bin", { timeout = 1 })
        ok_fail("HTTP download requires an existing parent directory", v, e)

        v, e = H.download("http://127.0.0.1:1/",
            "_babet_http_test/../out.bin", { timeout = 1 })
        ok_fail("HTTP download rejects '..' in destination", v, e)

        ok("HTTP download validation leaves no destination",
            not babet.fileExists(validation_path))
    end

    -- Chantier longjmp : ces erreurs runtime de http_perform passent
    -- maintenant en (nil, err) au lieu de luaL_error (cohérent avec
    -- le commentaire d'intention du fichier + évite les fuites C++).
    do
        local v, e = H.request({})
        ok_fail("request{} without url -> (nil, err)", v, e)
    end
    do
        local v, e = H.request({ url = 123 })
        ok_fail("request{url=number} -> (nil, err)", v, e)
    end
    do
        local v, e = H.request({ url = "http://127.0.0.1:1/", headers = "x" })
        ok_fail("request{headers=string} -> (nil, err)", v, e)
    end
    do
        local v, e = H.request({ url = "http://x/", timeout = "x" })
        ok_fail("request{timeout=string} -> (nil, err)", v, e)
    end

    do
        local v, e = H.request({
            url = "http://127.0.0.1:1/", verify = 1,
        })
        ok_fail("LOT 4 http.verify non-boolean -> (nil, err)", v, e)
        ok("  verify error mentions boolean",
            tostring(e):find("boolean", 1, true) ~= nil,
            "err=" .. tostring(e))

        v, e = H.request({
            url = "http://127.0.0.1:1/", follow_redirects = "yes",
        })
        ok_fail("LOT 4 http.follow_redirects non-boolean -> (nil, err)", v, e)
        ok("  follow_redirects error mentions boolean",
            tostring(e):find("boolean", 1, true) ~= nil,
            "err=" .. tostring(e))

        for _, bad in ipairs({ 0, -1, 1.5, 2147483649 }) do
            v, e = H.request({
                url = "http://127.0.0.1:1/", max_body_size = bad,
            })
            ok_fail("LOT 4 http.max_body_size rejected: " .. tostring(bad),
                v, e)
        end
    end

    do
        local v, e = H.request({ url = "http://127.0.0.1/\0ignored" })
        ok_fail("LOT 3 http: NUL in URL rejected", v, e)

        v, e = H.request({
            url = "http://127.0.0.1/",
            method = "GET\0POST",
        })
        ok_fail("LOT 3 http: NUL in method rejected", v, e)

        v, e = H.request({
            url = "https://127.0.0.1/",
            ca_cert = "/tmp/ca.pem\0ignored",
        })
        ok_fail("LOT 3 http: NUL in ca_cert rejected", v, e)

        v, e = H.request({
            url = "http://127.0.0.1/",
            headers = { ["X-Test\0Ignored"] = "ok" },
        })
        ok_fail("LOT 3 http: NUL in header name rejected", v, e)

        v, e = H.request({
            url = "http://127.0.0.1/",
            headers = { ["X-Test"] = "ok\0ignored" },
        })
        ok_fail("LOT 3 http: NUL in header value rejected", v, e)

        v, e = H.get("http://127.0.0.1/\r\nX-Evil: yes")
        ok_fail("DOC 4 HTTP rejects CR/LF in URL", v, e)

        v, e = H.request({
            url = "http://127.0.0.1/",
            headers = { ["Bad Header"] = "x" },
        })
        ok_fail("DOC 4 HTTP rejects invalid header name", v, e)

        v, e = H.request({
            url = "http://127.0.0.1/",
            headers = { ["X-é"] = "x" },
        })
        ok_fail("DOC 4 HTTP rejects non-ASCII header name", v, e)

        v, e = H.request({
            url = "http://127.0.0.1/",
            headers = { ["X-Test"] = "ok\r\nX-Evil: yes" },
        })
        ok_fail("DOC 4 HTTP rejects CR/LF in header value", v, e)

        v, e = H.request({
            url = "http://127.0.0.1/",
            query = { [{}] = "bad" },
        })
        ok_fail("DOC 4 HTTP rejects non-string query key", v, e)

        v, e = H.request({
            url = "http://127.0.0.1/",
            query = { bad = {} },
        })
        ok_fail("DOC 4 HTTP rejects non scalar query value", v, e)
    end

    -- mauvaises VALEURS d'option -> (nil, err), pas d'exception
    do
        local v, e = H.request({ url = "notaurl" })
        ok_fail("url without scheme -> (nil, err)", v, e)
        ok("  message mentions 'scheme'",
            type(e) == "string" and e:find("scheme", 1, true) ~= nil,
            "err=" .. tostring(e))

        v, e = H.get("ftp://example.com/")
        ok_fail("scheme not supported -> (nil, err)", v, e)

        v, e = H.get("http://")
        ok_fail("url without host -> (nil, err)", v, e)

        v, e = H.request({ url = "http://127.0.0.1:1/", timeout = -1 })
        ok_fail("timeout <= 0 -> (nil, err)", v, e)

        -- Régression (audit v21) : NaN/Inf/valeurs énormes dans
        -- timeout. L'ancien test `> 0` rejetait NaN par accident
        -- (message trompeur) et laissait passer math.huge et les
        -- finis énormes -> cast size_t/time_t indéfini plus bas.
        -- Ces validations précèdent tout accès réseau : aucune
        -- connexion tentée, tests hermétiques. Les vérifications de
        -- MESSAGE sont les vrais gardes de régression (l'ancien code
        -- rendait aussi (nil, err) mais avec une erreur de connexion
        -- ou un message trompeur).
        v, e = H.request({ url = "http://127.0.0.1:1/", timeout = 0 / 0 })
        ok_fail("timeout NaN -> (nil, err)", v, e)
        ok("  message mentions 'finite'",
            type(e) == "string" and e:find("finite", 1, true) ~= nil,
            "err=" .. tostring(e))

        v, e = H.request({
            url = "http://127.0.0.1:1/",
            timeout = math.huge
        })
        ok_fail("timeout math.huge -> (nil, err)", v, e)
        ok("  message mentions 'finite'",
            type(e) == "string" and e:find("finite", 1, true) ~= nil,
            "err=" .. tostring(e))

        v, e = H.request({ url = "http://127.0.0.1:1/", timeout = 1e300 })
        ok_fail("timeout 1e300 -> (nil, err)", v, e)
        ok("  message mentions 'too large'",
            type(e) == "string" and e:find("too large", 1, true) ~= nil,
            "err=" .. tostring(e))

        v, e = H.request({
            url = "http://127.0.0.1:1/", method = "FOO", timeout = 1,
        })
        ok_fail("unknown method -> (nil, err)", v, e)
        ok("  message mentions 'method'",
            type(e) == "string" and e:find("method", 1, true) ~= nil,
            "err=" .. tostring(e))

        v, e = H.request({
            url = "http://127.0.0.1:1/",
            method = "GET",
            body = "x",
            timeout = 1,
        })
        ok_fail("body on GET -> (nil, err)", v, e)
        ok("  message mentions 'body not allowed'",
            type(e) == "string"
            and e:find("body not allowed", 1, true) ~= nil,
            "err=" .. tostring(e))
    end

    -- échec transport : port loopback closed -> (nil, "http: ...")
    -- (reste sur 127.0.0.1, aucun accès réseau externe ; timeout court)
    do
        local v, e = H.get("http://127.0.0.1:1/", { timeout = 1 })
        ok_fail("loopback connection refused -> (nil, err)", v, e)
        ok("  err prefixed with 'http: '",
            type(e) == "string" and e:find("http: ", 1, true) == 1,
            "err=" .. tostring(e))
    end

    -- --- OPTIONAL success : only if python3 is present ----------
    local function have_python3()
        local r = babet.exec("python3", { "--version" })
        return type(r) == "table" and r.code == 0
    end

    if not have_python3() then
        print("[INFO] http: python3 absent, 2xx success subsection "
            .. "ignorée (hermétique, aucun prérequis dur)")
    else
        local SBH = "_babet_http_test"
        babet.rmdirAll(SBH)
        babet.mkdir(SBH)

        local server_file = assert(io.open(SBH .. "/server.py", "wb"))
        server_file:write([[
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import sys
import time

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _read_body(self):
        length = int(self.headers.get("Content-Length", "0"))
        return self.rfile.read(length) if length else b""

    def _send(self, status, body=b"", headers=()):
        self.send_response(status)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD" and body:
            self.wfile.write(body)
        self.wfile.flush()
        self.close_connection = True

    def _write_fragmented(self, data):
        if not data:
            return
        split = max(1, len(data) // 2)
        self.wfile.write(data[:split])
        self.wfile.flush()
        self.wfile.write(data[split:])
        self.wfile.flush()

    def _send_chunked(self, status, body=b"", headers=(),
                      chunk_sizes=(4096,), extensions=False,
                      trailers=(), fragmented=False, terminate=True):
        self.send_response(status)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("Transfer-Encoding", "chunked")
        if trailers:
            self.send_header("Trailer", ", ".join(name for name, _ in trailers))
        self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            offset = 0
            index = 0
            while offset < len(body):
                requested = chunk_sizes[index % len(chunk_sizes)]
                chunk = body[offset:offset + requested]
                suffix = ";babet=%d" % index if extensions else ""
                header = ("%X%s\r\n" % (len(chunk), suffix)).encode("ascii")
                if fragmented:
                    self._write_fragmented(header)
                    self._write_fragmented(chunk)
                    self._write_fragmented(b"\r\n")
                else:
                    self.wfile.write(header)
                    self.wfile.write(chunk)
                    self.wfile.write(b"\r\n")
                offset += len(chunk)
                index += 1
            if terminate:
                self.wfile.write(b"0\r\n")
                for name, value in trailers:
                    self.wfile.write((name + ": " + value + "\r\n").encode("ascii"))
                self.wfile.write(b"\r\n")
        self.wfile.flush()
        self.close_connection = True

    def _send_close_delimited(self, status, body=b"", headers=()):
        self.send_response(status)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD" and body:
            self.wfile.write(body)
        self.wfile.flush()
        self.close_connection = True

    def _echo(self):
        body = self._read_body()
        self._send(200, body, [
            ("Content-Type", "application/octet-stream"),
            ("X-Method", self.command),
            ("X-Request-Content-Type", self.headers.get("Content-Type", "")),
            ("X-Request-Number", self.headers.get("X-Number", "")),
        ])

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/probe.bin":
            self._send(200, b"AB\x00CD",
                       [("Content-Type", "application/octet-stream")])
        elif path == "/multi":
            self._send(200, b"ok", [
                ("Content-Type", "text/plain"),
                ("Set-Cookie", "a=1"),
                ("Set-Cookie", "b=2"),
            ])
        elif path == "/large":
            self._send(200, b"x" * 4096,
                       [("Content-Type", "application/octet-stream")])
        elif path == "/chunked":
            self._send_chunked(200, b"chunked-" * 16384,
                               [("Content-Type", "application/octet-stream")])
        elif path == "/chunked-fragmented":
            self._send_chunked(
                200, b"fragmented-" * 1000 + b"END",
                [("Content-Type", "application/octet-stream")],
                chunk_sizes=(1, 2, 3, 7, 31, 257, 4097),
                extensions=True,
                trailers=(("X-Chunked-Trailer", "complete"),),
                fragmented=True)
        elif path == "/chunked-truncated":
            self._send_chunked(
                200, b"incomplete",
                [("Content-Type", "application/octet-stream")],
                chunk_sizes=(32,), terminate=False)
        elif path == "/close-delimited":
            self._send_close_delimited(
                200, b"close---" * 16384,
                [("Content-Type", "application/octet-stream")])
        elif path == "/empty":
            self._send(204, b"",
                       [("Content-Type", "application/octet-stream")])
        elif path == "/query":
            self._send(200, self.path.encode("ascii"),
                       [("Content-Type", "text/plain")])
        elif path == "/redirect":
            self._send(302, b"redirect-body",
                       [("Location", "/probe.bin")])
        elif path == "/auth-redirect":
            target = "http://localhost:%d/auth-target" % self.server.server_port
            self._send(302, b"redirect-body", [("Location", target)])
        elif path == "/auth-target":
            auth = self.headers.get("Authorization", "").encode("utf-8")
            self._send(200, auth, [("Content-Type", "text/plain")])
        elif path == "/slow":
            time.sleep(0.5)
            self._send(200, b"slow", [("Content-Type", "text/plain")])
        else:
            self._send(404, b"not found",
                       [("Content-Type", "text/plain")])

    def do_HEAD(self):
        self._send(200, b"head-body", [("Content-Type", "text/plain")])

    def do_OPTIONS(self):
        self._send(204, b"", [("Allow", "GET,HEAD,OPTIONS,POST,PUT,PATCH,DELETE")])

    def do_POST(self):
        self._echo()

    def do_PUT(self):
        self._echo()

    def do_PATCH(self):
        self._echo()

    def do_DELETE(self):
        self._echo()

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1], "w", encoding="ascii") as port_file:
    port_file.write(str(server.server_port))
    port_file.flush()
server.serve_forever()
]])
        server_file:close()

        print("[INFO] http: starting local test server...")
        local port_file = SBH .. "/port.txt"

        -- Port éphémère attribué par le noyau : les trois exécutions
        -- successives du harnais ne peuvent plus se disputer un port
        -- calculé à partir de os.time(). Le userdata process garantit
        -- aussi que le serveur est réellement terminé avant la relance.
        local server_proc, server_err = babet.spawn("python3", {
            "server.py", "port.txt",
        }, {
            cwd = SBH,
            launch_timeout = 5,
        })

        -- Budget d'attente DUR et COURT : 15 sondes x ~200 ms ≈ 3 s
        -- max, AVEC progression visible (jamais "aucun avancement").
        -- Not ready within budget -> skip: the subsection is
        -- optionnelle (décision actée), on ne grind jamais en muet.
        local port
        local up = false
        if server_proc then
            for i = 1, 15 do
                babet.sleep(200, "ms")

                local pf = io.open(port_file, "rb")
                if pf then
                    local raw_port = pf:read("*a")
                    pf:close()
                    port = tonumber(raw_port)
                end

                if port and port >= 1 and port <= 65535 then
                    local probe = babet.http.get(
                        "http://127.0.0.1:" .. port .. "/probe.bin",
                        { timeout = 1 })
                    if type(probe) == "table" and probe.status == 200 then
                        up = true
                        break
                    end
                end

                if i % 5 == 0 then
                    print("[INFO] http: attente serveur ("
                        .. i .. "/15)...")
                end
            end
        end

        if not up then
            print("[INFO] http: local server unavailable in "
                .. "budget, 2xx success subsection ignorée (optionnelle)"
                .. "; err=" .. tostring(server_err))
            if server_proc then
                server_proc:close()
            end
            babet.rmdirAll(SBH)
        else
            local base = "http://127.0.0.1:" .. port
            print("[INFO] http: server ready, running 2xx success tests...")

            local download_dir = SBH .. "/downloads"
            assert(babet.mkdir(download_dir))

            local function read_binary(path)
                local file = assert(io.open(path, "rb"))
                local data = file:read("*a")
                file:close()
                return data
            end

            local function write_binary(path, data)
                local file = assert(io.open(path, "wb"))
                file:write(data)
                file:close()
            end

            local function count_download_temps(path)
                local files = babet.listFiles(path) or {}
                local count = 0
                for _, item in ipairs(files) do
                    local name = babet.getBasename(item)
                    if type(name) == "string"
                        and name:find(".babet-download.", 1, true) == 1 then
                        count = count + 1
                    end
                end
                return count
            end

            local download_path = download_dir .. "/probe.bin"
            local downloaded, download_err = H.download(
                base .. "/probe.bin", download_path, { timeout = 5 })
            ok("HTTP download 200 -> (table, nil)",
                type(downloaded) == "table" and download_err == nil,
                "err=" .. tostring(download_err))
            ok("HTTP download status == 200",
                type(downloaded) == "table" and downloaded.status == 200)
            ok("HTTP download reports saved=true",
                type(downloaded) == "table" and downloaded.saved == true)
            ok("HTTP download reports exact byte count",
                type(downloaded) == "table" and downloaded.bytes == 5,
                "bytes=" .. tostring(downloaded and downloaded.bytes))
            ok("HTTP download returns the destination path",
                type(downloaded) == "table"
                and downloaded.path == download_path)
            ok("HTTP download result does not expose an in-memory body",
                type(downloaded) == "table" and downloaded.body == nil)
            ok("HTTP download returns response headers",
                type(downloaded) == "table"
                and type(downloaded.headers) == "table"
                and downloaded.headers["content-type"]
                    == "application/octet-stream")
            ok("HTTP download returns headers_multi",
                type(downloaded) == "table"
                and type(downloaded.headers_multi) == "table"
                and type(downloaded.headers_multi["content-type"])
                    == "table")
            ok("HTTP download writes binary-safe content",
                read_binary(download_path) == "AB\0CD")

            local chunked_download_path = download_dir .. "/chunked.bin"
            local chunked_download, chunked_download_err = H.download(
                base .. "/chunked", chunked_download_path, {
                    timeout = 5,
                    max_file_size = 131072,
                })
            ok("HTTP download accepts a chunked response at exact limit",
                type(chunked_download) == "table"
                and chunked_download_err == nil
                and chunked_download.status == 200
                and chunked_download.saved == true
                and chunked_download.bytes == 131072,
                "err=" .. tostring(chunked_download_err))
            ok("HTTP chunked download writes the complete body",
                read_binary(chunked_download_path)
                    == string.rep("chunked-", 16384))

            local chunked_limited_path = download_dir
                .. "/chunked-limited.bin"
            write_binary(chunked_limited_path, "CHUNKED-ORIGINAL")
            local chunked_limited, chunked_limited_err = H.download(
                base .. "/chunked", chunked_limited_path, {
                    timeout = 5,
                    max_file_size = 131071,
                })
            ok_fail("HTTP chunked download enforces max_file_size boundary",
                chunked_limited, chunked_limited_err)
            ok("HTTP chunked download limit error is explicit",
                chunked_limited == nil
                and tostring(chunked_limited_err):find(
                    "max_file_size", 1, true) ~= nil,
                "err=" .. tostring(chunked_limited_err))
            ok("HTTP chunked download limit preserves destination",
                read_binary(chunked_limited_path) == "CHUNKED-ORIGINAL")
            ok("HTTP chunked download limit removes temporary file",
                count_download_temps(download_dir) == 0)

            local close_download_path = download_dir .. "/close-delimited.bin"
            local close_download, close_download_err = H.download(
                base .. "/close-delimited", close_download_path, {
                    timeout = 5,
                    max_file_size = 131072,
                })
            ok("HTTP download accepts a close-delimited response",
                type(close_download) == "table"
                and close_download_err == nil
                and close_download.status == 200
                and close_download.saved == true
                and close_download.bytes == 131072,
                "err=" .. tostring(close_download_err))
            ok("HTTP close-delimited download writes the complete body",
                read_binary(close_download_path)
                    == string.rep("close---", 16384))

            local truncated_download_path = download_dir
                .. "/chunked-truncated.bin"
            write_binary(truncated_download_path, "TRUNCATED-ORIGINAL")
            local truncated_download, truncated_download_err = H.download(
                base .. "/chunked-truncated", truncated_download_path, {
                    timeout = 5,
                    max_file_size = 1024,
                })
            ok_fail("HTTP download rejects a truncated chunked response",
                truncated_download, truncated_download_err)
            ok("HTTP truncated chunked download preserves destination",
                read_binary(truncated_download_path) == "TRUNCATED-ORIGINAL")
            ok("HTTP truncated chunked download removes temporary file",
                count_download_temps(download_dir) == 0)

            write_binary(download_path, "OLD")
            local replaced, replace_err = H.download(
                base .. "/probe.bin", download_path, { timeout = 5 })
            ok("HTTP download atomically replaces an existing file",
                type(replaced) == "table" and replace_err == nil
                and replaced.saved == true
                and read_binary(download_path) == "AB\0CD",
                "err=" .. tostring(replace_err))

            local error_path = download_dir .. "/preserved.bin"
            write_binary(error_path, "KEEP")
            local not_found, not_found_err = H.download(
                base .. "/missing", error_path, { timeout = 5 })
            ok("HTTP download 404 returns response metadata",
                type(not_found) == "table" and not_found_err == nil
                and not_found.status == 404,
                "err=" .. tostring(not_found_err))
            ok("HTTP download 404 reports saved=false",
                type(not_found) == "table" and not_found.saved == false)
            ok("HTTP download 404 reports received bytes",
                type(not_found) == "table" and not_found.bytes == 9,
                "bytes=" .. tostring(not_found and not_found.bytes))
            ok("HTTP download 404 exposes no destination path",
                type(not_found) == "table" and not_found.path == nil)
            ok("HTTP download 404 preserves the existing destination",
                read_binary(error_path) == "KEEP")
            ok("HTTP download 404 leaves no temporary file",
                count_download_temps(download_dir) == 0)

            local limited_path = download_dir .. "/limited.bin"
            write_binary(limited_path, "ORIGINAL")
            local limited, limited_err = H.download(
                base .. "/large", limited_path, {
                    timeout = 5,
                    max_file_size = 1024,
                })
            ok_fail("HTTP download enforces max_file_size",
                limited, limited_err)
            ok("HTTP download max_file_size error is explicit",
                limited == nil
                and tostring(limited_err):find(
                    "max_file_size", 1, true) ~= nil,
                "err=" .. tostring(limited_err))
            ok("HTTP download size failure preserves destination",
                read_binary(limited_path) == "ORIGINAL")
            ok("HTTP download size failure removes temporary file",
                count_download_temps(download_dir) == 0)

            local redirect_path = download_dir .. "/redirect.bin"
            write_binary(redirect_path, "REDIRECT-OLD")
            local redirect_result, redirect_err = H.download(
                base .. "/redirect", redirect_path, { timeout = 5 })
            ok("HTTP download does not follow redirects by default",
                type(redirect_result) == "table" and redirect_err == nil
                and redirect_result.status == 302
                and redirect_result.saved == false,
                "err=" .. tostring(redirect_err))
            ok("HTTP download unfollowed redirect preserves destination",
                read_binary(redirect_path) == "REDIRECT-OLD")

            local followed_download, followed_download_err = H.download(
                base .. "/redirect", redirect_path, {
                    timeout = 5,
                    follow_redirects = true,
                })
            ok("HTTP download follows redirects when requested",
                type(followed_download) == "table"
                and followed_download_err == nil
                and followed_download.status == 200
                and followed_download.saved == true
                and read_binary(redirect_path) == "AB\0CD",
                "err=" .. tostring(followed_download_err))

            local empty_path = download_dir .. "/empty.bin"
            local empty_result, empty_err = H.download(
                base .. "/empty", empty_path, { timeout = 5 })
            ok("HTTP download saves an empty 204 response",
                type(empty_result) == "table" and empty_err == nil
                and empty_result.status == 204
                and empty_result.saved == true
                and empty_result.bytes == 0,
                "err=" .. tostring(empty_err))
            ok("HTTP download creates an empty destination file",
                babet.fileExists(empty_path)
                and babet.fileSize(empty_path) == 0)

            local query_path = download_dir .. "/query.txt"
            local query_download, query_download_err = H.download(
                base .. "/query", query_path, {
                    timeout = 5,
                    query = { a = "x y" },
                })
            ok("HTTP download supports query options",
                type(query_download) == "table"
                and query_download_err == nil
                and read_binary(query_path):find("a=x+y", 1, true) ~= nil,
                "err=" .. tostring(query_download_err))

            local real_parent = SBH .. "/download-real-parent"
            local linked_parent = SBH .. "/download-linked-parent"
            assert(babet.mkdir(real_parent))
            assert(babet.link(real_parent, linked_parent))
            local through_link, through_link_err = H.download(
                base .. "/probe.bin", linked_parent .. "/blocked.bin", {
                    timeout = 5,
                })
            ok_fail("HTTP download rejects a symlink parent component",
                through_link, through_link_err)
            ok("HTTP download symlink-parent error is explicit",
                through_link == nil
                and tostring(through_link_err):find(
                    "symlink", 1, true) ~= nil,
                "err=" .. tostring(through_link_err))
            ok("HTTP download never writes through a symlink parent",
                not babet.fileExists(real_parent .. "/blocked.bin"))

            local symlink_target = download_dir .. "/target.bin"
            local symlink_destination = download_dir .. "/destination.bin"
            write_binary(symlink_target, "TARGET")
            assert(babet.link(symlink_target, symlink_destination))
            local symlink_result, symlink_err = H.download(
                base .. "/probe.bin", symlink_destination, { timeout = 5 })
            local no_longer_link = babet.exec("test", {
                "!", "-L", symlink_destination,
            })
            ok("HTTP download safely replaces a destination symlink",
                type(symlink_result) == "table" and symlink_err == nil
                and symlink_result.saved == true,
                "err=" .. tostring(symlink_err))
            ok("HTTP download leaves the symlink target untouched",
                read_binary(symlink_target) == "TARGET")
            ok("HTTP download destination now contains response data",
                read_binary(symlink_destination) == "AB\0CD")
            ok("HTTP download replaces the symlink inode itself",
                type(no_longer_link) == "table" and no_longer_link.code == 0)

            local transport_path = download_dir .. "/transport.bin"
            write_binary(transport_path, "STILL-HERE")
            local transport, transport_err = H.download(
                "http://127.0.0.1:1/", transport_path, { timeout = 1 })
            ok_fail("HTTP download transport failure -> (nil, err)",
                transport, transport_err)
            ok("HTTP download transport failure preserves destination",
                read_binary(transport_path) == "STILL-HERE")
            ok("HTTP download transport failure removes temporary file",
                count_download_temps(download_dir) == 0)

            local res, err = babet.http.get(base .. "/probe.bin",
                { timeout = 5 })
            ok("GET 200 -> (table, nil)",
                type(res) == "table" and err == nil,
                "err=" .. tostring(err))
            if type(res) == "table" then
                ok("  status == 200", res.status == 200,
                    "status=" .. tostring(res.status))
                ok("  body binary-safe (#==5, NUL preserved)",
                    type(res.body) == "string" and #res.body == 5
                    and res.body:byte(3) == 0,
                    "len=" .. tostring(#res.body))
                ok("  headers is a table",
                    type(res.headers) == "table")
                ok("  header key lowercased (content-type)",
                    type(res.headers) == "table"
                    and type(res.headers["content-type"]) == "string",
                    "ct=" .. tostring(res.headers
                        and res.headers["content-type"]))
                ok("LOT 4 headers_multi contains single-valued headers",
                    type(res.headers_multi) == "table"
                    and type(res.headers_multi["content-type"]) == "table"
                    and #res.headers_multi["content-type"] == 1,
                    "headers_multi=" .. tostring(res.headers_multi))
            end

            local multi, multi_err = babet.http.get(base .. "/multi",
                { timeout = 5 })
            local cookies = type(multi) == "table"
                and type(multi.headers_multi) == "table"
                and multi.headers_multi["set-cookie"] or nil
            local saw_cookie_a, saw_cookie_b = false, false
            if type(cookies) == "table" then
                for _, cookie in ipairs(cookies) do
                    saw_cookie_a = saw_cookie_a or cookie == "a=1"
                    saw_cookie_b = saw_cookie_b or cookie == "b=2"
                end
            end
            ok("LOT 4 repeated response headers -> headers_multi",
                type(multi) == "table" and multi_err == nil
                and type(multi.headers["set-cookie"]) == "string"
                and type(cookies) == "table" and #cookies == 2
                and saw_cookie_a and saw_cookie_b,
                "err=" .. tostring(multi_err))

            local too_big, too_big_err = babet.http.get(base .. "/large",
                { timeout = 5, max_body_size = 1024 })
            ok_fail("LOT 4 HTTP body over max_body_size -> (nil, err)",
                too_big, too_big_err)
            ok("  no partial body and explicit max_body_size error",
                too_big == nil
                and tostring(too_big_err):find("max_body_size", 1, true) ~= nil,
                "err=" .. tostring(too_big_err))

            local large_ok, large_err = babet.http.get(base .. "/large",
                { timeout = 5, max_body_size = 8192 })
            ok("LOT 4 custom max_body_size permits response",
                type(large_ok) == "table" and large_err == nil
                and type(large_ok.body) == "string"
                and #large_ok.body == 4096,
                "err=" .. tostring(large_err))

            local chunked, chunked_err = babet.http.get(base .. "/chunked", {
                timeout = 5,
                max_body_size = 131072,
            })
            ok("HTTP chunked response is read completely at exact limit",
                type(chunked) == "table" and chunked_err == nil
                and chunked.status == 200
                and chunked.body == string.rep("chunked-", 16384),
                "len=" .. tostring(chunked and #chunked.body)
                    .. " err=" .. tostring(chunked_err))

            local chunked_too_big, chunked_too_big_err = babet.http.get(
                base .. "/chunked", {
                    timeout = 5,
                    max_body_size = 131071,
                })
            ok_fail("HTTP chunked response enforces max_body_size boundary",
                chunked_too_big, chunked_too_big_err)
            ok("  chunked limit exposes no partial body and stays explicit",
                chunked_too_big == nil
                and tostring(chunked_too_big_err):find(
                    "max_body_size", 1, true) ~= nil,
                "err=" .. tostring(chunked_too_big_err))

            local fragmented, fragmented_err = babet.http.get(
                base .. "/chunked-fragmented", {
                    timeout = 5,
                    max_body_size = 11003,
                })
            -- cpp-httplib consumes the trailing section but stores its fields
            -- separately from the initial response headers. Babet does not
            -- currently expose that separate trailer collection; successful
            -- completion plus the declared Trailer header verifies the framing.
            ok("HTTP fragmented chunked response supports extensions and trailers",
                type(fragmented) == "table" and fragmented_err == nil
                and fragmented.body == string.rep("fragmented-", 1000) .. "END"
                and type(fragmented.headers) == "table"
                and fragmented.headers["trailer"] == "X-Chunked-Trailer",
                "err=" .. tostring(fragmented_err))

            local close_delimited, close_delimited_err = babet.http.get(
                base .. "/close-delimited", {
                    timeout = 5,
                    max_body_size = 131072,
                })
            ok("HTTP close-delimited response is read completely",
                type(close_delimited) == "table"
                and close_delimited_err == nil
                and close_delimited.status == 200
                and close_delimited.body == string.rep("close---", 16384),
                "err=" .. tostring(close_delimited_err))

            local close_too_big, close_too_big_err = babet.http.get(
                base .. "/close-delimited", {
                    timeout = 5,
                    max_body_size = 131071,
                })
            ok_fail("HTTP close-delimited response enforces max_body_size",
                close_too_big, close_too_big_err)
            ok("  close-delimited limit exposes no partial body",
                close_too_big == nil
                and tostring(close_too_big_err):find(
                    "max_body_size", 1, true) ~= nil,
                "err=" .. tostring(close_too_big_err))

            local truncated_chunked, truncated_chunked_err = babet.http.get(
                base .. "/chunked-truncated", {
                    timeout = 5,
                    max_body_size = 1024,
                })
            ok_fail("HTTP truncated chunked response is rejected",
                truncated_chunked, truncated_chunked_err)
            ok("  truncated chunked response exposes no partial body",
                truncated_chunked == nil
                and type(truncated_chunked_err) == "string"
                and truncated_chunked_err:find("http: ", 1, true) == 1,
                "err=" .. tostring(truncated_chunked_err))

            local r404, e404 = babet.http.get(
                base .. "/nexiste_pas", { timeout = 5 })
            ok("GET 404 -> (table, nil) [4xx is not an error]",
                type(r404) == "table" and e404 == nil
                and r404.status == 404,
                "status=" .. tostring(r404 and r404.status)
                .. " err=" .. tostring(e404))

            local rq = babet.http.get(base .. "/query",
                { timeout = 5, query = { a = "x y", b = 42 } })
            ok("DOC 4 GET query uses documented normalization",
                type(rq) == "table" and rq.status == 200
                and rq.body:find("a=x+y", 1, true) ~= nil
                and rq.body:find("b=42", 1, true) ~= nil,
                "body=" .. tostring(rq and rq.body))

            local rq_utf8 = babet.http.get(base .. "/query", {
                timeout = 5, query = { word = "café" },
            })
            ok("DOC 4 GET query percent-encodes UTF-8 bytes",
                type(rq_utf8) == "table" and rq_utf8.status == 200
                and rq_utf8.body:find("word=caf%%C3%%A9") ~= nil,
                "body=" .. tostring(rq_utf8 and rq_utf8.body))

            local rq2 = babet.http.get(
                base .. "/query?already=hello%20world#ignored", {
                    timeout = 5, query = { more = "a/b" },
                })
            ok("DOC 4 query merges existing query and strips fragment",
                type(rq2) == "table"
                and rq2.body:find("already=hello+world", 1, true) ~= nil
                and rq2.body:find("more=a/b", 1, true) ~= nil
                and rq2.body:find("ignored", 1, true) == nil,
                "body=" .. tostring(rq2 and rq2.body))

            local post1, post1_err = babet.http.post(base .. "/echo",
                "AB\0CD", { timeout = 5, headers = { ["X-Number"] = 42 } })
            ok("DOC 4 post(url, body, opts) is binary-safe",
                type(post1) == "table" and post1_err == nil
                and post1.body == "AB\0CD",
                "err=" .. tostring(post1_err))
            ok("DOC 4 body defaults to application/octet-stream",
                type(post1) == "table"
                and post1.headers["x-request-content-type"]
                    == "application/octet-stream")
            ok("DOC 4 numeric request header is converted to text",
                type(post1) == "table"
                and post1.headers["x-request-number"] == "42")

            local post2 = babet.http.post(base .. "/echo", {
                timeout = 5,
                body = "from-opts",
                headers = { ["Content-Type"] = "text/plain" },
            })
            ok("DOC 4 post(url, opts) uses opts.body",
                type(post2) == "table" and post2.body == "from-opts")
            ok("DOC 4 explicit Content-Type is preserved",
                type(post2) == "table"
                and post2.headers["x-request-content-type"] == "text/plain")

            local post3 = babet.http.post(base .. "/echo", "argument", {
                timeout = 5, body = "ignored-option",
            })
            ok("DOC 4 positional POST body overrides opts.body",
                type(post3) == "table" and post3.body == "argument")

            local put = babet.http.request({
                url = base .. "/echo", method = "put", body = "payload",
                timeout = 5,
            })
            ok("DOC 4 method is case-insensitive and normalized",
                type(put) == "table" and put.body == "payload"
                and put.headers["x-method"] == "PUT")

            local redir = babet.http.get(base .. "/redirect", { timeout = 5 })
            ok("DOC 4 redirects are not followed by default",
                type(redir) == "table" and redir.status == 302
                and redir.headers.location == "/probe.bin")
            local followed, followed_err = babet.http.get(
                base .. "/redirect", {
                    timeout = 5, follow_redirects = true,
                })
            ok("DOC 4 follow_redirects=true follows redirect",
                type(followed) == "table" and followed.status == 200
                and followed.body == "AB\0CD",
                "status=" .. tostring(followed and followed.status)
                .. " body=" .. tostring(followed and followed.body)
                .. " err=" .. tostring(followed_err))

            local cross_origin, cross_origin_err = babet.http.get(
                base .. "/auth-redirect", {
                    timeout = 5,
                    follow_redirects = true,
                    headers = { Authorization = "Bearer babet-secret" },
                })
            ok("HTTP cross-origin redirect strips Authorization",
                type(cross_origin) == "table"
                and cross_origin.status == 200
                and cross_origin.body == "",
                "body=" .. tostring(cross_origin and cross_origin.body)
                .. " err=" .. tostring(cross_origin_err))

            local head = babet.http.request({
                url = base .. "/anything", method = "HEAD", timeout = 5,
            })
            ok("DOC 4 HEAD returns headers with an empty body",
                type(head) == "table" and head.status == 200
                and head.body == "")

            local slow_started = babet.time.monotonic()
            local slow, slow_err = babet.http.get(base .. "/slow",
                { timeout = 0.1 })
            local slow_elapsed = babet.time.monotonic() - slow_started
            ok_fail("DOC 4 HTTP timeout covers the request", slow, slow_err)
            ok("  timeout remains bounded",
                slow == nil and slow_elapsed < 2.0,
                "elapsed=" .. tostring(slow_elapsed)
                .. " err=" .. tostring(slow_err))

            -- close() termine et reap le groupe de processus avant de
            -- supprimer les fichiers du serveur. Aucun serveur résiduel
            -- ne peut donc perturber l'exécution embarquée via PATH.
            server_proc:close()
            babet.rmdirAll(SBH)
        end
    end
    -- --- dette de test post-Chantier 1 (4 cas inscrits au `todo`) ----

    -- 1. http.post(url, opts) without body: 2-arg form (opts in 2nd
    -- position, pas de string body). On vise un port loopback closed
    -- pour rester hermétique ; ce qu'on prouve, c'est que la forme
    -- est ACCEPTÉE (no luaL_error « body must be a string », pas
    -- de « body not allowed for POST ») et que la requête atteint le
    -- transport, qui échoue alors proprement.
    do
        local v, e = H.post("http://127.0.0.1:1/", { timeout = 1 })
        ok_fail("post(url, opts) without body: form accepted, "
            .. "transport échoue -> (nil, err)", v, e)
        ok("  err prefixed with 'http: ' (not 'body must be a string')",
            type(e) == "string"
            and e:find("http: ", 1, true) == 1
            and e:find("body must be", 1, true) == nil,
            "err=" .. tostring(e))
    end

    -- 2. URL malformée subtile : "http:///path" (host empty entre les
    -- `//` et le `/`). Expected rejection by split_url (« missing host »).
    do
        local v, e = H.get("http:///path")
        ok_fail("http:///path -> (nil, err)", v, e)
        ok("  message mentions 'host'",
            type(e) == "string"
            and e:find("host", 1, true) ~= nil,
            "err=" .. tostring(e))
    end

    -- 3. Malformed URL: "http://:8080/" (port without host). After
    -- split_url hardening (post-chantier 7 work), this is
    -- rejected AT PARSE with message "missing host", instead of waiting for
    -- a transport failure. Faster and more precise.
    do
        local v, e = H.get("http://:8080/")
        ok_fail("http://:8080/ : rejected at parse -> (nil, err)", v, e)
        ok("  err mentions 'host'",
            type(e) == "string"
            and e:find("host", 1, true) ~= nil,
            "err=" .. tostring(e))
    end

    -- 3b. URL malformée : "http://[]:8080/" (crochets IPv6 emptys).
    -- Consistent with SU-3: authority starts with '[' but the host
    -- entre [] est empty -> rejet au parse.
    do
        local v, e = H.get("http://[]:8080/")
        ok_fail("http://[]:8080/ : rejected at parse -> (nil, err)", v, e)
        ok("  err mentions 'host'",
            type(e) == "string"
            and e:find("host", 1, true) ~= nil,
            "err=" .. tostring(e))
    end

    -- 4. IPv6 brut loopback closed : prouve que [::1] est accepted par
    -- the parse, transport fails cleanly (refused or IPv6 error
    -- selon configuration locale).
    do
        local v, e = H.get("http://[::1]:1/", { timeout = 1 })
        ok_fail("http://[::1]:1/ : IPv6 parse OK, transport fails"
            .. " -> (nil, err)", v, e)
        ok("  err prefixed with 'http: '",
            type(e) == "string"
            and e:find("http: ", 1, true) == 1,
            "err=" .. tostring(e))
    end
end

-- =====================================================================
end
