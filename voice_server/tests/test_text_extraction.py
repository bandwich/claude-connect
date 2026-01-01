import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from content_models import TextBlock, ThinkingBlock, ToolUseBlock
from ios_server import extract_text_for_tts


def test_extract_text_from_text_blocks():
    """Test extracting text from only text blocks"""
    blocks = [
        TextBlock(type="text", text="First"),
        TextBlock(type="text", text="Second")
    ]
    result = extract_text_for_tts(blocks)
    assert result == "First Second"


def test_extract_text_ignores_thinking():
    """Test that thinking blocks are ignored"""
    blocks = [
        TextBlock(type="text", text="Hello"),
        ThinkingBlock(type="thinking", thinking="Internal", signature="sig"),
        TextBlock(type="text", text="World")
    ]
    result = extract_text_for_tts(blocks)
    assert result == "Hello World"


def test_extract_text_ignores_tool_use():
    """Test that tool_use blocks are ignored"""
    blocks = [
        TextBlock(type="text", text="Answer"),
        ToolUseBlock(type="tool_use", id="t1", name="Tool", input={}),
        TextBlock(type="text", text="Done")
    ]
    result = extract_text_for_tts(blocks)
    assert result == "Answer Done"


def test_extract_text_empty_list():
    """Test extracting from empty list returns empty string"""
    result = extract_text_for_tts([])
    assert result == ""


def test_extract_text_no_text_blocks():
    """Test extracting when no text blocks present"""
    blocks = [
        ThinkingBlock(type="thinking", thinking="Think", signature="sig"),
        ToolUseBlock(type="tool_use", id="t1", name="Tool", input={})
    ]
    result = extract_text_for_tts(blocks)
    assert result == ""
