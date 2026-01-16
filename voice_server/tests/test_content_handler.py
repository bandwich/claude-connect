import json
import asyncio

from voice_server.ios_server import VoiceServer
from voice_server.content_models import AssistantResponse, TextBlock
import pytest


@pytest.mark.asyncio
async def test_handle_content_response_sends_message():
    """Test that handle_content_response sends JSON message to clients"""
    server = VoiceServer()

    # Mock websocket
    sent_messages = []

    class MockWebSocket:
        async def send(self, message):
            sent_messages.append(message)

    mock_ws = MockWebSocket()
    server.clients.add(mock_ws)

    # Create test response
    response = AssistantResponse(
        content_blocks=[TextBlock(type="text", text="Test")],
        timestamp=123.456
    )

    # Call handler
    await server.handle_content_response(response)

    # Verify message was sent
    assert len(sent_messages) == 1
    data = json.loads(sent_messages[0])
    assert data["type"] == "assistant_response"
    assert data["timestamp"] == 123.456
    assert len(data["content_blocks"]) == 1


@pytest.mark.asyncio
async def test_handle_content_response_multiple_clients():
    """Test that content is sent to all connected clients"""
    server = VoiceServer()

    sent_messages = []

    class MockWebSocket:
        def __init__(self, id):
            self.id = id

        async def send(self, message):
            sent_messages.append((self.id, message))

    # Add multiple clients
    server.clients.add(MockWebSocket(1))
    server.clients.add(MockWebSocket(2))

    response = AssistantResponse(
        content_blocks=[TextBlock(type="text", text="Test")],
        timestamp=123.456
    )

    await server.handle_content_response(response)

    # Verify all clients received message
    assert len(sent_messages) == 2
