# voice_server/http_server.py
"""HTTP server for Claude Code permission hooks"""

import json
from aiohttp import web
from permission_handler import PermissionHandler

HTTP_PORT = 8766


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

        request_id = payload.get("request_id", "")

        await permission_handler.broadcast({
            "type": "permission_resolved",
            "request_id": request_id,
            "answered_in": "terminal"
        })

        permission_handler.cleanup_request(request_id)

        return web.json_response({"status": "ok"})

    async def handle_health(request: web.Request) -> web.Response:
        """Health check endpoint"""
        return web.json_response({"status": "ok"})

    app = web.Application()
    app.router.add_post("/permission", handle_permission)
    app.router.add_post("/permission_resolved", handle_permission_resolved)
    app.router.add_get("/health", handle_health)

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
