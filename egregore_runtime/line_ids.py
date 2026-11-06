"""Read legacy memory line ids without the optional document editor."""
import re

ID = re.compile(r"[ \t]+<!-- \^([0-9a-z]{6}) -->[ \t]*$")


def unmarked(text: str) -> str:
    """``text`` without the id comment at its end: what a line says, for a reader."""
    return ID.sub("", str(text))

