#!/usr/bin/env python3
"""Minimal MCP client for the local Figma Dev Mode server.

Usage:
  figma-mcp.py init                 # initialize + notifications/initialized
  figma-mcp.py tools                # tools/list (names + descriptions)
  figma-mcp.py call <tool> '<json>'  # tools/call with JSON arguments
"""
import json
import os
import sys
import urllib.error
import urllib.request

URL = "http://127.0.0.1:3845/mcp"
SESSION_FILE = "/tmp/figma-mcp-session"


def post(payload, session=None, timeout=120):
    request = urllib.request.Request(URL, data=json.dumps(payload).encode(), method="POST")
    request.add_header("Content-Type", "application/json")
    request.add_header("Accept", "application/json, text/event-stream")
    if session:
        request.add_header("Mcp-Session-Id", session)
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.headers.get("mcp-session-id"), response.read().decode("utf-8", "replace")


def parse(body):
    messages = []
    for line in body.splitlines():
        if line.startswith("data: "):
            try:
                messages.append(json.loads(line[6:]))
            except json.JSONDecodeError:
                pass
    if not messages and body.strip().startswith("{"):
        messages.append(json.loads(body))
    return messages


def load_session():
    if os.path.exists(SESSION_FILE):
        return open(SESSION_FILE).read().strip()
    return None


def initialize():
    session, body = post({
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "dsh-cli", "version": "1.0"},
        },
    })
    if session:
        open(SESSION_FILE, "w").write(session)
    print("session:", session)
    for message in parse(body):
        result = message.get("result", {})
        info = result.get("serverInfo", {})
        print("server:", info.get("name"), info.get("version"), "| protocol:", result.get("protocolVersion"))
    # Required by the spec before any other request.
    post({"jsonrpc": "2.0", "method": "notifications/initialized"}, session=session)
    return session


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else "tools"
    session = load_session()

    if command == "init":
        initialize()
        return

    if session is None:
        session = initialize()

    if command == "tools":
        _, body = post({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}, session=session)
        for message in parse(body):
            if "error" in message:
                print("ERROR:", json.dumps(message["error"])[:400])
                continue
            for tool in message.get("result", {}).get("tools", []):
                description = (tool.get("description") or "").strip().splitlines()
                print(f"- {tool['name']}: {description[0] if description else ''}")
                schema = tool.get("inputSchema", {}).get("properties", {})
                if schema:
                    print(f"    args: {', '.join(schema)}")
        return

    if command == "call":
        tool = sys.argv[2]
        arguments = json.loads(sys.argv[3]) if len(sys.argv) > 3 else {}
        _, body = post({
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": {"name": tool, "arguments": arguments},
        }, session=session)
        for message in parse(body):
            if "error" in message:
                print("ERROR:", json.dumps(message["error"])[:600])
                continue
            for index, item in enumerate(message.get("result", {}).get("content", [])):
                if item.get("type") == "text":
                    print(item["text"])
                elif item.get("type") == "image" and item.get("data"):
                    import base64
                    suffix = "png" if "png" in (item.get("mimeType") or "") else "bin"
                    path = f"/tmp/figma-image-{tool}-{index}.{suffix}"
                    with open(path, "wb") as handle:
                        handle.write(base64.b64decode(item["data"]))
                    print(f"[saved image] {path} ({os.path.getsize(path)} bytes)")
                else:
                    print(f"[{item.get('type')}] {json.dumps({k: v for k, v in item.items() if k != 'data'})[:200]}")
        return

    print(__doc__)


if __name__ == "__main__":
    main()
