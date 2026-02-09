from pydantic import BaseModel
from typing import Literal, Any, Dict, Union


class TextBlock(BaseModel):
    type: Literal["text"]
    text: str


class ThinkingBlock(BaseModel):
    type: Literal["thinking"]
    thinking: str
    signature: str


class ToolUseBlock(BaseModel):
    type: Literal["tool_use"]
    id: str
    name: str
    input: Dict[str, Any]


class ToolResultBlock(BaseModel):
    type: Literal["tool_result"]
    tool_use_id: str
    content: str = ""
    is_error: bool = False


ContentBlock = Union[TextBlock, ThinkingBlock, ToolUseBlock, ToolResultBlock]


class AssistantResponse(BaseModel):
    type: Literal["assistant_response"] = "assistant_response"
    content_blocks: list[ContentBlock]
    timestamp: float
    is_incremental: bool = True  # True = more blocks may come, False = response complete
