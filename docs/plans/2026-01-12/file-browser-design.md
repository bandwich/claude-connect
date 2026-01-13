# File Browser & Viewer Design

## Overview

Add a file browser and viewer to the iOS app, allowing users to browse and view project files while using Claude Voice.

## Navigation Flow

```
ProjectsListView → ProjectDetailView (tabs) → SessionView or FileView
                        ├─ Sessions tab → SessionsListView content
                        └─ Files tab → FilesView → FileView
```

## Components

### ProjectDetailView (new)

Container view with segmented control for switching between Sessions and Files.

- Replaces direct navigation from ProjectsListView → SessionsListView
- Segmented control: `Sessions | Files`
- Sessions tab shows existing SessionsListView content
- Files tab shows new FilesView

### FilesView (new)

Expandable tree browser for project files.

- Fetches directory listing from server via WebSocket
- Shows folders (expandable) and files in a tree structure
- Tapping a folder expands/collapses it inline (loads children on expand)
- Tapping a file navigates to FileView
- Shows all files and folders (no filtering)
- Sort order: directories first, then files, both alphabetical

### FileView (new)

Plain text file viewer based on DiffView pattern.

- Monospace font
- Line numbers
- Scrollable content
- Header shows file path
- For binary/unreadable files: centered "Cannot view contents" message

## WebSocket Protocol

### List Directory

Request:
```json
{
  "type": "list_directory",
  "path": "/Users/aaron/Desktop/project"
}
```

Response:
```json
{
  "type": "directory_listing",
  "path": "/Users/aaron/Desktop/project",
  "entries": [
    {"name": "src", "type": "directory"},
    {"name": "tests", "type": "directory"},
    {"name": "README.md", "type": "file"},
    {"name": "setup.py", "type": "file"}
  ]
}
```

Entries are sorted: directories first, then files, both alphabetically.

### Read File

Request:
```json
{
  "type": "read_file",
  "path": "/Users/aaron/Desktop/project/README.md"
}
```

Success response:
```json
{
  "type": "file_contents",
  "path": "/Users/aaron/Desktop/project/README.md",
  "contents": "# Project\n\nThis is the readme..."
}
```

Error response (binary file):
```json
{
  "type": "file_contents",
  "path": "/Users/aaron/Desktop/project/image.png",
  "error": "binary_file"
}
```

## Files to Create/Modify

### iOS App

| File | Action |
|------|--------|
| `Views/ProjectDetailView.swift` | Create - tabbed container |
| `Views/FilesView.swift` | Create - tree browser |
| `Views/FileView.swift` | Create - text viewer |
| `Views/ProjectsListView.swift` | Modify - navigate to ProjectDetailView instead of SessionsListView |
| `Services/WebSocketManager.swift` | Modify - add listDirectory and readFile methods |

### Server

| File | Action |
|------|--------|
| `voice_server/ios_server.py` | Modify - handle list_directory and read_file messages |
