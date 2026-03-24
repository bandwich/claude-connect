"""
File Handler - handles file browsing and project creation requests.
"""

import base64
import json
import os
from typing import TYPE_CHECKING

from voice_server.infra.tmux_controller import session_name_for

if TYPE_CHECKING:
    from voice_server.server import VoiceServer

IMAGE_EXTENSIONS = {'.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.ico'}
MAX_IMAGE_SIZE = 10 * 1024 * 1024  # 10MB


class FileHandler:
    """Handles file browsing, reading, and project creation."""

    def __init__(self, server: "VoiceServer"):
        self.server = server

    async def handle_list_directory(self, websocket, data):
        """Handle list_directory request - returns files and folders in a directory"""
        path = data.get("path", "")

        if not path or not os.path.isdir(path):
            response = {
                "type": "directory_listing",
                "path": path,
                "entries": [],
                "error": "invalid_path"
            }
            await websocket.send(json.dumps(response))
            return

        try:
            entries = []
            for name in os.listdir(path):
                full_path = os.path.join(path, name)
                entry_type = "directory" if os.path.isdir(full_path) else "file"
                entries.append({"name": name, "type": entry_type})

            entries.sort(key=lambda e: (0 if e["type"] == "directory" else 1, e["name"].lower()))

            response = {
                "type": "directory_listing",
                "path": path,
                "entries": entries
            }
        except PermissionError:
            response = {
                "type": "directory_listing",
                "path": path,
                "entries": [],
                "error": "permission_denied"
            }

        await websocket.send(json.dumps(response))

    async def handle_read_file(self, websocket, data):
        """Handle read_file request - returns file contents as text, or base64 for images"""
        path = data.get("path", "")

        if not path or not os.path.isfile(path):
            response = {
                "type": "file_contents",
                "path": path,
                "error": "not_found"
            }
            await websocket.send(json.dumps(response))
            return

        ext = os.path.splitext(path)[1].lower()

        if ext in IMAGE_EXTENSIONS:
            file_size = os.path.getsize(path)
            if file_size > MAX_IMAGE_SIZE:
                response = {
                    "type": "file_contents",
                    "path": path,
                    "error": "file_too_large",
                    "file_size": file_size
                }
            else:
                with open(path, 'rb') as f:
                    image_bytes = f.read()
                response = {
                    "type": "file_contents",
                    "path": path,
                    "image_data": base64.b64encode(image_bytes).decode('utf-8'),
                    "image_format": ext.lstrip('.'),
                    "file_size": file_size
                }
            await websocket.send(json.dumps(response))
            return

        try:
            with open(path, 'r', encoding='utf-8') as f:
                contents = f.read()

            response = {
                "type": "file_contents",
                "path": path,
                "contents": contents
            }
        except UnicodeDecodeError:
            response = {
                "type": "file_contents",
                "path": path,
                "error": "binary_file"
            }
        except PermissionError:
            response = {
                "type": "file_contents",
                "path": path,
                "error": "permission_denied"
            }

        await websocket.send(json.dumps(response))

    async def handle_add_project(self, websocket, data):
        """Handle add_project request - creates directory and starts Claude"""
        from voice_server.services.transcript_watcher import poll_for_session_file

        name = data.get("name", "").strip()
        success = False
        project_path = ""

        if not name:
            response = {
                "type": "project_created",
                "success": False,
                "error": "Project name is required"
            }
            await websocket.send(json.dumps(response))
            return

        safe_name = "".join(c for c in name if c.isalnum() or c in "-_. ")
        project_path = os.path.join(self.server.projects_base_path, safe_name)

        try:
            os.makedirs(project_path, exist_ok=True)
            import uuid
            temp_id = f"pending-{uuid.uuid4().hex[:8]}"
            tmux_name = session_name_for(temp_id)
            success = self.server.tmux.start_session(tmux_name, working_dir=project_path)

            if success:
                self.server._active_tmux_session = tmux_name
                folder_name = self.server.session_manager.encode_path_to_folder(project_path)
                await poll_for_session_file(
                    find_fn=lambda: self.server.session_manager.find_newest_session(folder_name),
                    timeout=10.0,
                    interval=0.2
                )
                self.server.tmux.send_input(tmux_name, "")

        except Exception as e:
            print(f"Error creating project: {e}")

        response = {
            "type": "project_created",
            "success": success,
            "path": project_path,
            "name": safe_name
        }
        await websocket.send(json.dumps(response))
