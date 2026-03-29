# server/infra/http_server.py
"""HTTP server for Claude Code permission hooks and E2E test support"""

import asyncio
import json
from aiohttp import web
from server.services.permission_handler import PermissionHandler
from server.infra.tmux_controller import session_name_for

HTTP_PORT = 8766

# References to server components, set by ConnectServer
_tmux_controller = None
_server = None


def set_tmux_controller(controller):
    """Set the tmux controller reference for status endpoints"""
    global _tmux_controller
    _tmux_controller = controller


def set_server(server):
    """Set the server reference for transcript endpoints"""
    global _server
    _server = server


def resolve_session_id(raw_id: str) -> str:
    """Resolve a pending-* session ID to the real session ID.

    When a new session starts, the tmux process gets CLAUDE_CONNECT_SESSION_ID=pending-<uuid>.
    The real session ID is only known after deferred detection. This resolves the pending ID
    by looking up the SessionContext in the server's active_sessions dict.
    """
    if not raw_id.startswith("pending-") or not _server:
        return raw_id
    tmux_name = session_name_for(raw_id)
    ctx = _server.active_sessions.get(tmux_name)
    if ctx and ctx.session_id:
        return ctx.session_id
    # Not resolved yet — return empty so the iOS filter passes it through
    return ""


def is_viewed_session(raw_session_id: str) -> bool:
    """Check if the hook's session matches the currently viewed session.

    Returns True (allow broadcast) when:
    - No server ref (can't check, backward compat)
    - No viewed session (nothing to conflict with)
    - Session matches by tmux name or resolved session ID
    """
    if not _server:
        return True
    if not _server.viewed_session_id:
        return True
    if not raw_session_id:
        return False

    # Check by tmux session name (works for pending-* sessions too)
    tmux_name = session_name_for(raw_session_id)
    if _server._active_tmux_session == tmux_name:
        return True

    # Check by resolved session ID
    resolved = resolve_session_id(raw_session_id)
    if resolved and resolved == _server.viewed_session_id:
        return True

    return False


def create_http_app(permission_handler: PermissionHandler) -> web.Application:
    """Create the aiohttp application with permission endpoints"""

    async def handle_permission(request: web.Request) -> web.Response:
        """Handle POST /permission from PermissionRequest hook"""
        try:
            payload = await request.json()
        except json.JSONDecodeError:
            return web.json_response({"error": "Invalid JSON"}, status=400)

        raw_session_id = request.headers.get("X-Session-Id", "")

        if not is_viewed_session(raw_session_id):
            print(f"[PERM HTTP] Not viewed session ({raw_session_id!r}) — falling back to terminal")
            return web.json_response({"behavior": "ask"})

        timeout = float(request.query.get("timeout", "180"))

        request_id = permission_handler.generate_request_id()
        permission_handler.register_request(request_id)

        tool_name = payload.get("tool_name", "")
        prompt_type_map = {
            "Bash": "bash",
            "Write": "write",
            "Edit": "edit",
            "Task": "task",
        }
        prompt_type = prompt_type_map.get(tool_name, "bash")

        session_id = resolve_session_id(raw_session_id)

        ios_message = {
            "type": "permission_request",
            "request_id": request_id,
            "session_id": session_id,
            "prompt_type": prompt_type,
            "tool_name": tool_name,
            "tool_input": payload.get("tool_input", {}),
            "context": payload.get("context"),
            "permission_suggestions": payload.get("permission_suggestions"),
            "timestamp": payload.get("timestamp", 0),
        }

        print(f"[PERM HTTP] Broadcasting permission_request: id={request_id}, tool={tool_name}")
        print(f"[PERM HTTP] permission_suggestions from Claude Code: {json.dumps(payload.get('permission_suggestions'))}")
        await permission_handler.broadcast(ios_message)
        print(f"[PERM HTTP] Waiting for response (timeout={timeout}s)...")

        try:
            response = await permission_handler.wait_for_response(request_id, timeout=timeout)
        except asyncio.CancelledError:
            # HTTP connection dropped (Claude Code killed the hook)
            print(f"[PERM HTTP] Connection dropped for {request_id} — cleaning up")
            permission_handler.cleanup_request(request_id)
            raise

        if response is None:
            print(f"[PERM HTTP] wait_for_response returned None for {request_id} — falling back to terminal")
            return web.json_response({"behavior": "ask"})

        print(f"[PERM HTTP] Got response for {request_id}: {response.get('decision', '?')}")
        permission_handler.cleanup_request(request_id)

        # Format response for Claude Code hook (expects hookSpecificOutput wrapper)
        decision_behavior = response.get("decision", "deny")
        hook_decision = {
            "behavior": decision_behavior
        }

        # Include message for deny so Claude understands it was user-initiated
        if decision_behavior == "deny":
            hook_decision["message"] = "The user denied this action from the iOS app. Do not retry the same action — ask the user what they'd like instead."

        hook_response = {
            "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": hook_decision
            }
        }

        # Forward updatedPermissions if iOS sent them (for "always allow")
        updated_perms = response.get("updated_permissions")
        if updated_perms:
            hook_response["hookSpecificOutput"]["decision"]["updatedPermissions"] = updated_perms

        print(f"[PERM HTTP] Returning hook response for {request_id}: {json.dumps(hook_response)}")
        return web.json_response(hook_response)

    async def handle_question(request: web.Request) -> web.Response:
        """Handle POST /question from PreToolUse hook for AskUserQuestion.

        Receives question data, broadcasts each question to iOS one at a time,
        collects answers, returns deny decision with answers for Claude.
        """
        try:
            payload = await request.json()
        except json.JSONDecodeError:
            return web.json_response({"error": "Invalid JSON"}, status=400)

        raw_session_id = request.headers.get("X-Session-Id", "")

        if not is_viewed_session(raw_session_id):
            print(f"[QUESTION] Not viewed session ({raw_session_id!r}) — falling back to terminal")
            return web.json_response({"fallback": True})

        timeout = float(request.query.get("timeout", "180"))

        session_id = resolve_session_id(raw_session_id)

        tool_input = payload.get("tool_input", {})
        questions = tool_input.get("questions", [])

        if not questions:
            return web.json_response({"fallback": True})

        total = len(questions)
        answers = []

        for idx, q in enumerate(questions):
            request_id = permission_handler.generate_request_id()
            permission_handler.register_request(request_id)

            options = q.get("options", [])

            ios_message = {
                "type": "question_prompt",
                "request_id": request_id,
                "session_id": session_id,
                "header": q.get("header", ""),
                "question": q.get("question", ""),
                "options": options if options else [],
                "multi_select": q.get("multiSelect", False),
                "question_index": idx,
                "total_questions": total,
            }

            print(f"[QUESTION] Broadcasting question {idx+1}/{total}: {q.get('question', '')[:60]}")
            await permission_handler.broadcast(ios_message)

            try:
                response = await permission_handler.wait_for_response(request_id, timeout=timeout)
            except asyncio.CancelledError:
                print(f"[QUESTION] Connection dropped for {request_id}")
                permission_handler.cleanup_request(request_id)
                raise

            if response is None:
                print(f"[QUESTION] Timeout for question {idx+1}")
                await permission_handler.broadcast({
                    "type": "question_resolved",
                    "request_id": request_id,
                })
                return web.json_response({"fallback": True})

            permission_handler.cleanup_request(request_id)

            if response.get("dismissed"):
                print(f"[QUESTION] User dismissed question {idx+1}")
                await permission_handler.broadcast({
                    "type": "question_resolved",
                    "request_id": request_id,
                })
                return web.json_response({
                    "hookSpecificOutput": {
                        "hookEventName": "PreToolUse",
                        "permissionDecision": "deny",
                        "permissionDecisionReason": "The user dismissed this question from the iOS app. Do not ask again — proceed with your best judgment or ask a different question."
                    }
                })

            answer = response.get("answer", "")
            question_text = q.get("question", "")
            answers.append((question_text, answer))
            print(f"[QUESTION] Got answer for question {idx+1}: {answer[:60]}")

            # Broadcast resolved so iOS clears the prompt before next question
            await permission_handler.broadcast({
                "type": "question_resolved",
                "request_id": request_id,
            })

        # Build the deny reason with all answers
        answer_lines = []
        for q_text, a_text in answers:
            answer_lines.append(f'Q: "{q_text}"\nA: "{a_text}"')
        answers_block = "\n\n".join(answer_lines)

        hook_response = {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": f"The user already answered via the iOS app.\n\n{answers_block}\n\nProceed with these answers. Do not ask again."
            }
        }

        print(f"[QUESTION] Returning hook response with {len(answers)} answer(s)")
        return web.json_response(hook_response)

    async def handle_permission_resolved(request: web.Request) -> web.Response:
        """Handle POST /permission_resolved from PostToolUse hook.

        PostToolUse fires after EVERY tool completes, not just permission-gated ones.
        We must NOT resolve a pending PermissionRequest here — if a permission is
        truly pending, the PermissionRequest HTTP handler is still blocked waiting.
        Claude Code can't run the tool (and trigger PostToolUse) until that handler
        returns. So any PostToolUse while a request is pending is for a DIFFERENT tool.

        The only case we handle: a request that timed out (fell back to terminal).
        The user answered in terminal, the tool ran, PostToolUse fires. We broadcast
        permission_resolved so the iOS app dismisses the stale prompt.
        """
        try:
            payload = await request.json()
        except json.JSONDecodeError:
            return web.json_response({"error": "Invalid JSON"}, status=400)

        session_id = resolve_session_id(request.headers.get("X-Session-Id", ""))
        request_id = payload.get("request_id", "")

        if not request_id:
            return web.json_response({"status": "ok", "action": "no_request_id"})

        # If this request is still actively pending (iOS hasn't answered, hook still
        # blocked), this PostToolUse is for a different tool — ignore it.
        if permission_handler.is_request_pending(request_id):
            return web.json_response({"status": "ok", "action": "ignored_pending"})

        # If this request timed out (user answered in terminal), broadcast resolved
        # so iOS dismisses the stale prompt.
        if permission_handler.is_request_timed_out(request_id):
            await permission_handler.broadcast({
                "type": "permission_resolved",
                "request_id": request_id,
                "session_id": session_id,
                "answered_in": "terminal"
            })
            permission_handler.cleanup_request(request_id)
            return web.json_response({"status": "ok", "action": "resolved_timed_out"})

        # Already resolved or cleaned up — nothing to do
        return web.json_response({"status": "ok", "action": "already_resolved"})

    async def handle_health(request: web.Request) -> web.Response:
        """Health check endpoint"""
        return web.json_response({"status": "ok"})

    async def handle_tmux_status(request: web.Request) -> web.Response:
        """Check tmux session status - for E2E tests"""
        if _tmux_controller is None:
            return web.json_response({"error": "tmux controller not set"}, status=500)

        tmux_name = _server._active_tmux_session if _server else None
        return web.json_response({
            "available": _tmux_controller.is_available(),
            "session_exists": bool(tmux_name and _tmux_controller.session_exists(tmux_name))
        })

    async def handle_capture_pane(request: web.Request) -> web.Response:
        """Capture tmux pane content - for E2E tests to verify input arrived"""
        if _tmux_controller is None:
            return web.json_response({"error": "tmux controller not set"}, status=500)

        tmux_name = _server._active_tmux_session if _server else None
        content = _tmux_controller.capture_pane(tmux_name) if tmux_name else None
        if content is None:
            return web.json_response({"error": "no session"}, status=404)

        return web.json_response({"content": content})

    async def handle_set_transcript(request: web.Request) -> web.Response:
        """Set the transcript file path"""
        if _server is None:
            return web.json_response({"error": "server not set"}, status=500)

        try:
            payload = await request.json()
        except json.JSONDecodeError:
            return web.json_response({"error": "Invalid JSON"}, status=400)

        path = payload.get("path", "")
        if not path:
            return web.json_response({"error": "path required"}, status=400)

        # Update the server's transcript path and file watcher
        _server.transcript_path = path
        if hasattr(_server, 'handler') and _server.handler:
            _server.handler.expected_session_file = path
            _server.handler.processed_line_count = 0

        return web.json_response({"status": "ok", "path": path})

    async def handle_get_transcript(request: web.Request) -> web.Response:
        """Get the current transcript file path - for E2E tests"""
        if _server is None:
            return web.json_response({"error": "server not set"}, status=500)

        return web.json_response({
            "path": _server.transcript_path,
            "active_session_id": _server.active_session_id
        })

    async def handle_reset(request: web.Request) -> web.Response:
        """Reset server state for E2E test isolation

        Kills tmux session and clears all tracking state.
        Call at start of each test to ensure clean state.
        """
        if _server is None:
            return web.json_response({"error": "server not set"}, status=500)

        _server.reset_state()
        return web.json_response({"status": "ok", "message": "Server state reset"})

    app = web.Application()
    app.router.add_post("/permission", handle_permission)
    app.router.add_post("/question", handle_question)
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
