"""Claude Connect server package."""

from importlib.metadata import version, PackageNotFoundError

try:
    __version__ = version("claude-connect")
except PackageNotFoundError:
    __version__ = "0.1.0"
