# voice_server/http_server.py
"""HTTP server for Claude Code permission hooks and E2E test support"""

import json
from aiohttp import web
from voice_server.permission_handler import PermissionHandler

HTTP_PORT = 8766

# References to server components, set by VoiceServer
_tmux_controller = None
_voice_server = None


def set_tmux_controller(controller):
    """Set the tmux controller reference for status endpoints"""
    global _tmux_controller
    _tmux_controller = controller


def set_voice_server(server):
    """Set the voice server reference for transcript endpoints"""
    global _voice_server
    _voice_server = server


def create_http_app(permission_handler: PermissionHandler) -> web.Application:
    """Create the aiohttp application with permission endpoints"""

    async def handle_permission(request: web.Request) -> web.Response:
        """Handle POST /permission from PermissionRequest hook"""
        try:
            payload = await request.json()
        except json.JSONDecodeError:
            return web.json_response({"error": "Invalid JSON"}, status=400)

        timeout = float(request.query.get("timeout", "180"))

        request_id = permission_handler.generate_request_id()
        permission_handler.register_request(request_id)

        tool_name = payload.get("tool_name", "")
        prompt_type_map = {
            "Bash": "bash",
            "Write": "write",
            "Edit": "edit",
            "AskUserQuestion": "question",
            "Task": "task",
        }
        prompt_type = prompt_type_map.get(tool_name, "bash")

        ios_message = {
            "type": "permission_request",
            "request_id": request_id,
            "prompt_type": prompt_type,
            "tool_name": tool_name,
            "tool_input": payload.get("tool_input", {}),
            "context": payload.get("context"),
            "question": payload.get("question"),
            "timestamp": payload.get("timestamp", 0),
        }

        await permission_handler.broadcast(ios_message)

        response = await permission_handler.wait_for_response(request_id, timeout=timeout)

        if response is None:
            return web.json_response({"behavior": "ask"})

        permission_handler.cleanup_request(request_id)

        # Format response for Claude Code hook (expects hookSpecificOutput wrapper)
        hook_response = {
            "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": {
                    "behavior": response.get("decision", "deny")
                }
            }
        }
        return web.json_response(hook_response)

    async def handle_permission_resolved(request: web.Request) -> web.Response:
        """Handle POST /permission_resolved from PostToolUse hook"""
        try:
            payload = await request.json()
        except json.JSONDecodeError:
            return web.json_response({"error": "Invalid JSON"}, status=400)

        # PostToolUse payload from Claude Code won't have our server-generated
        # request_id, so fall back to the latest pending request
        request_id = payload.get("request_id", "") or permission_handler.latest_request_id or ""

        await permission_handler.broadcast({
            "type": "permission_resolved",
            "request_id": request_id,
            "answered_in": "terminal"
        })

        permission_handler.cleanup_request(request_id)
        if request_id == permission_handler.latest_request_id:
            permission_handler.latest_request_id = None

        return web.json_response({"status": "ok"})

    async def handle_health(request: web.Request) -> web.Response:
        """Health check endpoint"""
        return web.json_response({"status": "ok"})

    async def handle_tmux_status(request: web.Request) -> web.Response:
        """Check tmux session status - for E2E tests"""
        if _tmux_controller is None:
            return web.json_response({"error": "tmux controller not set"}, status=500)

        return web.json_response({
            "available": _tmux_controller.is_available(),
            "session_exists": _tmux_controller.session_exists()
        })

    async def handle_capture_pane(request: web.Request) -> web.Response:
        """Capture tmux pane content - for E2E tests to verify input arrived"""
        if _tmux_controller is None:
            return web.json_response({"error": "tmux controller not set"}, status=500)

        content = _tmux_controller.capture_pane()
        if content is None:
            return web.json_response({"error": "no session"}, status=404)

        return web.json_response({"content": content})

    async def handle_set_transcript(request: web.Request) -> web.Response:
        """Set the transcript file path"""
        if _voice_server is None:
            return web.json_response({"error": "voice server not set"}, status=500)

        try:
            payload = await request.json()
        except json.JSONDecodeError:
            return web.json_response({"error": "Invalid JSON"}, status=400)

        path = payload.get("path", "")
        if not path:
            return web.json_response({"error": "path required"}, status=400)

        # Update the server's transcript path and file watcher
        _voice_server.transcript_path = path
        if hasattr(_voice_server, 'handler') and _voice_server.handler:
            _voice_server.handler.expected_session_file = path
            _voice_server.handler.processed_line_count = 0

        return web.json_response({"status": "ok", "path": path})

    async def handle_get_transcript(request: web.Request) -> web.Response:
        """Get the current transcript file path - for E2E tests"""
        if _voice_server is None:
            return web.json_response({"error": "voice server not set"}, status=500)

        return web.json_response({
            "path": _voice_server.transcript_path,
            "active_session_id": _voice_server.active_session_id
        })

    async def handle_reset(request: web.Request) -> web.Response:
        """Reset server state for E2E test isolation

        Kills tmux session and clears all tracking state.
        Call at start of each test to ensure clean state.
        """
        if _voice_server is None:
            return web.json_response({"error": "voice server not set"}, status=500)

        _voice_server.reset_state()
        return web.json_response({"status": "ok", "message": "Server state reset"})

    app = web.Application()
    app.router.add_post("/permission", handle_permission)
    app.router.add_post("/permission_resolved", handle_permission_resolved)
    app.router.add_get("/health", handle_health)
    app.router.add_get("/tmux_status", handle_tmux_status)
    app.router.add_get("/capture_pane", handle_capture_pane)
    app.router.add_post("/set_transcript", handle_set_transcript)
    app.router.add_get("/transcript", handle_get_transcript)
    app.router.add_post("/reset", handle_reset)

    return app


async def start_http_server(
    permission_handler: PermissionHandler,
    port: int = HTTP_PORT
) -> web.AppRunner:
    """Start the HTTP server"""
    app = create_http_app(permission_handler)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "0.0.0.0", port)
    await site.start()
    print(f"HTTP server running on http://0.0.0.0:{port}")
    return runner
