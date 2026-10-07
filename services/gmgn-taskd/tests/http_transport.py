"""Standard-library HTTP/SSE test transport; never uses the legacy wire protocol."""
import http.client
import json
from pathlib import Path


class Connection:
    def __init__(self, endpoint_path):
        endpoint = json.loads(Path(endpoint_path).read_text())
        host, port = endpoint["address"].rsplit(":", 1)
        if endpoint["version"] != 2 or host != "127.0.0.1" or not 0 < int(port) < 65536:
            raise OSError("invalid HTTP endpoint")
        self.auth = endpoint["token"]
        self.http = http.client.HTTPConnection(host, int(port), timeout=8)
        self.http.connect()
        self.response = None
        self.streaming = False

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()

    def sendall(self, encoded):
        # Existing business tests express requests as JSON, not raw HTTP bytes.
        value = json.loads(encoded)
        token = value.pop("auth", None)
        self.streaming = value["method"] in ("subscribe", "subscribe_messages", "world_subscribe")
        headers = {"Content-Type": "application/json"}
        if token is not None:
            headers["Authorization"] = "Bearer " + token
        self.http.request("POST", "/events" if self.streaming else "/rpc", json.dumps(value).encode(), headers)
        self.response = self.http.getresponse()
        if self.streaming and self.response.status == 200:
            if self.response.getheader("Content-Type", "").split(";", 1)[0] != "text/event-stream":
                raise AssertionError("event subscription is not an SSE response")
        elif self.streaming:
            self.streaming = False

    def makefile(self, mode):
        return self

    def readline(self):
        if not self.streaming:
            return self.response.read()
        data = []
        while True:
            line = self.response.readline()
            if not line:
                return b""
            if line in (b"\n", b"\r\n"):
                if data:
                    return b"\n".join(data)
            elif line.startswith(b"data:"):
                data.append(line[5:].lstrip().rstrip(b"\r\n"))

    def settimeout(self, timeout):
        self.http.sock.settimeout(timeout)

    def close(self):
        if self.response is not None:
            self.response.close()
        self.http.close()
