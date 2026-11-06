"""Load a separately delivered module; failures inside installed code still raise."""
from importlib import import_module
from importlib.util import resolve_name


def optional_module(name: str):
    absolute = resolve_name(name, __package__)
    try:
        return import_module(absolute)
    except ModuleNotFoundError as exc:
        if exc.name != absolute:
            raise
        return None
