"""Tool modules, and the parameter types they share."""

from decimal import Decimal, InvalidOperation
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


def _number_text(value, handler):
    """A JSON number or numeric string as exact decimal text; None stays None."""
    if value is None:
        return None
    if isinstance(value, bool):
        raise ValueError("expected a number, not a boolean")
    if isinstance(value, (int, float)):
        # repr is the shortest text that round-trips the double, so 0.1 is
        # sent as "0.1" and compared with numeric 0.1, not 0.1000000000000000055.
        text = repr(value)
    else:
        text = handler(value).strip()
    try:
        number = Decimal(text)
    except InvalidOperation:
        raise ValueError(f"{text!r} is not a number") from None
    if not number.is_finite():
        raise ValueError(f"{text!r} is not a finite number")
    return text


# An optional number filter: a JSON number, a numeric string ("1200.5"), or
# None / omitted for "do not filter". Annotated `str` for the same reason as
# OptText -- under any other annotation FastMCP JSON-decodes the text "null"
# to None and the filter disappears; here "null" is refused as not a number.
# The value reaches SQL as decimal text cast to numeric, so it is compared
# exactly with the stored numeric.
OptNumber = Annotated[
    str,
    WrapValidator(_number_text),
    WithJsonSchema({"anyOf": [{"type": "number"}, {"type": "string"}, {"type": "null"}]}),
]
