"""Tool modules, and the one parameter type they share."""

from typing import Annotated

from pydantic import WithJsonSchema, WrapValidator

# An optional text filter: a string, or None / omitted for "do not filter".
#
# `Optional[str]` would say the same, but FastMCP JSON-decodes a string
# argument whenever the parameter is not annotated exactly `str` (so that a
# list sent as '["a", "b"]' still works), and that turns the *text* "null"
# into None: get_subjects(subject_id="null") silently dropped its filter and
# returned every subject. Annotating the parameter `str` keeps the text as
# typed; the wrap validator lets a real JSON null through as None, and the
# JSON schema is spelled out so that clients still see "string or null",
# exactly as for Optional[str]. tests/test_tools_integration.py pins this
# against the installed FastMCP.
OptText = Annotated[
    str,
    WrapValidator(lambda value, handler: None if value is None else handler(value)),
    WithJsonSchema({"anyOf": [{"type": "string"}, {"type": "null"}]}),
]
