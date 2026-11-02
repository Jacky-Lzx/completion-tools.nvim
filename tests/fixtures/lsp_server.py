"""Deterministic stdio LSP fixture; no external dependencies.

Uses UTF-16, defaults/insert-replace ranges, delayed resolve, incomplete lists,
commands and deliberately responds even to cancelled requests.
"""
import json
import re
import sys
import threading

write_lock = threading.Lock()
documents = {}
extra_label = None


def send(message):
    payload = json.dumps(message, ensure_ascii=False).encode()
    with write_lock:
        sys.stdout.buffer.write(f"Content-Length: {len(payload)}\r\n\r\n".encode() + payload)
        sys.stdout.buffer.flush()


def trace(kind, **values):
    send({"jsonrpc": "2.0", "method": "completionFixture/trace", "params": {"kind": kind, **values}})


def respond(request_id, result, delay=0):
    message = {"jsonrpc": "2.0", "id": request_id, "result": result}
    if delay:
        timer = threading.Timer(delay, send, (message,))
        timer.daemon = True
        timer.start()
    else:
        send(message)


def units(text):
    return len(text.encode("utf-16-le")) // 2


def index(text, character):
    for i in range(len(text) + 1):
        if units(text[:i]) >= character:
            return i
    return len(text)


def handle(message):
    global extra_label
    method = message.get("method")
    params = message.get("params") or {}
    request_id = message.get("id")
    if method == "initialize":
        extra_label = (params.get("initializationOptions") or {}).get("extra_label")
        trace("capabilities", snippet=params["capabilities"]["textDocument"]["completion"]["completionItem"]["snippetSupport"])
        respond(request_id, {"capabilities": {"positionEncoding": "utf-16", "textDocumentSync": 1,
            "completionProvider": {"triggerCharacters": [".", "λ"], "resolveProvider": True},
            "executeCommandProvider": {"commands": ["fixture.accept"]}}})
    elif method == "textDocument/didOpen":
        documents[params["textDocument"]["uri"]] = params["textDocument"]["text"]
    elif method == "textDocument/didChange":
        # The fixture advertises full sync.
        documents[params["textDocument"]["uri"]] = params["contentChanges"][-1]["text"]
    elif method == "textDocument/completion":
        text = documents[params["textDocument"]["uri"]]
        row, character = params["position"]["line"], params["position"]["character"]
        line = text.split("\n")[row]
        before = line[:index(line, character)]
        match = re.search(r"[A-Za-z_]*$", before)
        prefix = match.group()
        start = {"line": row, "character": units(before[:match.start()])}
        end = {"line": row, "character": character}
        replacement_end = {"line": row, "character": units(line)}
        labels = ["foobar", "forest", extra_label] if not prefix.startswith("inc") else ["incompleteValue"]
        items = [{"label": label, "kind": 6, "textEditText": label,
                  "data": {"row": row, "uri": params["textDocument"]["uri"]}} for label in labels if label]
        trace("completion", prefix=prefix, **params.get("context", {}))
        respond(request_id, {"isIncomplete": prefix.startswith("inc"), "itemDefaults": {
            "editRange": {"insert": {"start": start, "end": end},
                          "replace": {"start": start, "end": replacement_end}},
            "insertTextFormat": 1}, "items": items}, 0.07 if prefix == "f" else 0.005)
    elif method == "completionItem/resolve":
        result = dict(params)
        result["detail"] = "resolved fixture member"
        result["documentation"] = {"kind": "markdown", "value": "Fixture documentation."}
        result["additionalTextEdits"] = [{"range": {"start": {"line": 0, "character": 0},
            "end": {"line": 0, "character": 0}}, "newText": "import fixture\n"}]
        result["command"] = {"title": "Accept fixture", "command": "fixture.accept"}
        trace("resolve", label=params["label"])
        respond(request_id, result, 0.08)
    elif method == "workspace/executeCommand":
        trace("execute", command=params["command"])
        respond(request_id, None)
    elif method == "shutdown":
        respond(request_id, None)
    elif method == "exit":
        raise SystemExit(0)
    elif request_id is not None:
        respond(request_id, None)


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
    payload = sys.stdin.buffer.read(int(headers["content-length"]))
    handle(json.loads(payload))
