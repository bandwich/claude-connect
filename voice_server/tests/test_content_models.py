import pytest
import time

from voice_server.content_models import TextBlock, ThinkingBlock, ToolUseBlock, AssistantResponse


def test_text_block_valid():
    """Test TextBlock accepts valid data"""
    block = TextBlock(type="text", text="Hello world")
    assert block.type == "text"
    assert block.text == "Hello world"


def test_text_block_serialization():
    """Test TextBlock serializes to dict correctly"""
    block = TextBlock(type="text", text="Hello")
    data = block.model_dump()
    assert data == {"type": "text", "text": "Hello"}


def test_text_block_from_dict():
    """Test TextBlock parses from dict"""
    data = {"type": "text", "text": "Hello"}
    block = TextBlock(**data)
    assert block.text == "Hello"


def test_thinking_block_valid():
    """Test ThinkingBlock accepts valid data"""
    block = ThinkingBlock(
        type="thinking",
        thinking="Internal reasoning",
        signature="abc123"
    )
    assert block.type == "thinking"
    assert block.thinking == "Internal reasoning"
    assert block.signature == "abc123"


def test_thinking_block_requires_signature():
    """Test ThinkingBlock requires signature field"""
    with pytest.raises(Exception):  # Pydantic ValidationError
        ThinkingBlock(type="thinking", thinking="Test")


def test_tool_use_block_valid():
    """Test ToolUseBlock accepts valid data"""
    block = ToolUseBlock(
        type="tool_use",
        id="toolu_123",
        name="TestTool",
        input={"param": "value"}
    )
    assert block.type == "tool_use"
    assert block.id == "toolu_123"
    assert block.name == "TestTool"
    assert block.input == {"param": "value"}


def test_tool_use_block_nested_input():
    """Test ToolUseBlock handles nested input objects"""
    block = ToolUseBlock(
        type="tool_use",
        id="toolu_123",
        name="TestTool",
        input={"nested": {"key": "value"}, "list": [1, 2, 3]}
    )
    assert block.input["nested"]["key"] == "value"
    assert block.input["list"] == [1, 2, 3]


def test_assistant_response_with_text_blocks():
    """Test AssistantResponse with text blocks"""
    blocks = [
        TextBlock(type="text", text="First"),
        TextBlock(type="text", text="Second")
    ]
    response = AssistantResponse(content_blocks=blocks, timestamp=time.time())
    assert response.type == "assistant_response"
    assert len(response.content_blocks) == 2


def test_assistant_response_with_mixed_blocks():
    """Test AssistantResponse with different block types"""
    blocks = [
        TextBlock(type="text", text="Hello"),
        ThinkingBlock(type="thinking", thinking="Hmm", signature="sig"),
        ToolUseBlock(type="tool_use", id="t1", name="Tool", input={})
    ]
    response = AssistantResponse(content_blocks=blocks, timestamp=time.time())
    assert len(response.content_blocks) == 3


def test_assistant_response_serialization():
    """Test AssistantResponse serializes correctly"""
    blocks = [TextBlock(type="text", text="Test")]
    response = AssistantResponse(content_blocks=blocks, timestamp=123.456)
    data = response.model_dump()
    assert data["type"] == "assistant_response"
    assert data["timestamp"] == 123.456
    assert len(data["content_blocks"]) == 1
    assert data["content_blocks"][0]["type"] == "text"


def test_assistant_response_incremental_flag():
    """Test that AssistantResponse can indicate incremental vs complete"""
    # Incremental response (default for streaming)
    incremental = AssistantResponse(
        content_blocks=[TextBlock(type="text", text="Hello")],
        timestamp=123.456,
        is_incremental=True
    )
    assert incremental.is_incremental is True

    # Complete response (when conversation ends)
    complete = AssistantResponse(
        content_blocks=[TextBlock(type="text", text="Goodbye")],
        timestamp=789.012,
        is_incremental=False
    )
    assert complete.is_incremental is False


def test_assistant_response_serialization_includes_flag():
    """Test that model_dump includes is_incremental"""
    response = AssistantResponse(
        content_blocks=[TextBlock(type="text", text="Hi")],
        timestamp=123.0,
        is_incremental=True
    )

    data = response.model_dump()
    assert "is_incremental" in data
    assert data["is_incremental"] is True
