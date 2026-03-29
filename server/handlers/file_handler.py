"""
File Handler - handles file browsing and project creation requests.
"""

import base64
import json
import os
from typing import TYPE_CHECKING



if TYPE_CHECKING:
    from server.main import ConnectServer

IMAGE_EXTENSIONS = {'.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.ico'}
MAX_IMAGE_SIZE = 10 * 1024 * 1024  # 10MB


class FileHandler:
    """Handles file browsing, reading, and project creation."""

    def __init__(self, server: "ConnectServer"):
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
        """Handle add_project request - creates project directory"""
        name = data.get("name", "").strip()

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
            success = True
        except Exception as e:
            print(f"Error creating project: {e}")
            success = False

        response = {
            "type": "project_created",
            "success": success,
            "path": project_path,
            "name": safe_name
        }
        try:
            await websocket.send(json.dumps(response))
        except Exception:
            pass  # Client may have reconnected

        if success:
            await self.server.broadcast_projects_list()
