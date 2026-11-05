"""Copilot-only stdio fixture: incremental sync, cycling, device auth and feedback."""
import json
import sys
import time

log = sys.argv[1]


def send(request_id, result):
    payload = json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result}).encode()
    sys.stdout.buffer.write(f"Content-Length: {len(payload)}\r\n\r\n".encode() + payload)
    sys.stdout.buffer.flush()


while True:
    headers = {}
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            raise SystemExit(0)
        if line in (b"\r\n", b"\n"):
            break
        name, value = line.decode().split(":", 1)
        headers[name.lower()] = value.strip()
    message = json.loads(sys.stdin.buffer.read(int(headers["content-length"])))
    with open(log, "a") as output:
        output.write(json.dumps(message) + "\n")
    method = message.get("method")
    request_id = message.get("id")
    params = message.get("params", {})
    if method == "initialize":
        time.sleep(0.05)
        send(request_id, {"capabilities": {"positionEncoding": "utf-16", "textDocumentSync": 2,
             "workspace": {"workspaceFolders": {"supported": True, "changeNotifications": True}},
             "executeCommandProvider": {"commands": ["fixture.finishDeviceFlow"]}}})
    elif method in ("getCompletions", "getCompletionsCycling"):
        if len(sys.argv) > 2 and method == "getCompletionsCycling":
            time.sleep(float(sys.argv[2]))
        row = params["position"]["line"]
        send(request_id, {"completions": [
            {"text": f'print({i})\nprint("done")', "uuid": f"candidate-{i}",
             "range": {"start": {"line": row, "character": 6}, "end": params["position"]}}
            for i in range(1, 2 if method == "getCompletions" else 4)]})
    elif method == "signIn":
        send(request_id, {"userCode": "TEST-CODE", "command": {
             "command": "fixture.finishDeviceFlow", "arguments": [], "title": "Sign in"}})
    elif method == "shutdown":
        send(request_id, None)
    elif method == "exit":
        raise SystemExit(0)
    elif request_id is not None:
        send(request_id, {})
