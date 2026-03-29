from server.models.content_models import TextBlock, ThinkingBlock, ToolUseBlock
from server.services.tts_manager import extract_text_for_tts, strip_markdown_for_speech


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


def test_strip_markdown_bold():
    assert strip_markdown_for_speech("This is **bold** text") == "This is bold text"


def test_strip_markdown_italic():
    assert strip_markdown_for_speech("This is *italic* text") == "This is italic text"


def test_strip_markdown_bold_italic():
    assert strip_markdown_for_speech("This is ***bold italic*** text") == "This is bold italic text"


def test_strip_markdown_inline_code():
    assert strip_markdown_for_speech("Run `npm install` now") == "Run npm install now"


def test_strip_markdown_links():
    assert strip_markdown_for_speech("See [this page](https://example.com) for details") == "See this page for details"


def test_strip_markdown_headings():
    assert strip_markdown_for_speech("### Section Title") == "Section Title"
    assert strip_markdown_for_speech("# Top Level") == "Top Level"


def test_strip_markdown_plain_text_unchanged():
    assert strip_markdown_for_speech("No markdown here") == "No markdown here"


def test_extract_text_strips_markdown():
    """Test that extract_text_for_tts strips markdown from text blocks"""
    blocks = [TextBlock(type="text", text="This is **bold** and *italic*")]
    result = extract_text_for_tts(blocks)
    assert result == "This is bold and italic"
