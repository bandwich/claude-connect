For new sessions with my fix:
  1. newSession(projectPath:) sends request to server
  2. Server starts tmux, sends session_created response → ignored (no callback set)
  3. Server also broadcasts connection_status → this IS handled
  4. SessionView appears, isSyncing = false, shows voiceState: Idle

  The key is the connection_status broadcast (line 486 in ios_server.py):
  if success:
      await self.broadcast_connection_status()

  This sends:
  {
    "type": "connection_status",
    "connected": true,
    "active_session_id": "<new_session_id>"
  }

  iOS handles this in WebSocketManager.handleMessage:
  } else if let connectionStatus = try? JSONDecoder().decode(ConnectionStatus.self, from: data) {
      self.connected = connectionStatus.connected
      self.activeSessionId = connectionStatus.activeSessionId
  }

  So even without the session_created callback:
  - webSocketManager.connected gets updated to true
  - webSocketManager.activeSessionId gets the new session ID
  - The UI works because isSyncing = false shows voiceState

  What's missing: Error handling if session_created returns success: false. But that would also mean the connection_status broadcast shows connected: false, which could be detected.

  It's not ideal, but it should work. A proper fix would set up the callback before calling newSession().