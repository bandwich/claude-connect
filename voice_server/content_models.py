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


ContentBlock = Union[TextBlock, ThinkingBlock, ToolUseBlock]


class AssistantResponse(BaseModel):
    type: Literal["assistant_response"] = "assistant_response"
    content_blocks: list[ContentBlock]
    timestamp: float
    is_incremental: bool = True  # True = more blocks may come, False = response complete
