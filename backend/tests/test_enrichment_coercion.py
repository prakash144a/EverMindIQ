"""The LLM's JSON is untrusted input.

Gemini is asked for strings but sometimes answers with arrays. ``Recording`` is a
Pydantic model without ``validate_assignment``, so a list assigned to a ``str``
field is accepted silently, stored, and only blows up in the client's parsing —
which is how "type 'List<dynamic>' is not a subtype of type 'String?'" reached
the app. Coerce at the boundary instead.
"""

from app.services.gemini import _as_text, _as_text_list


def test_as_text_flattens_a_list():
    assert _as_text(["reflective", "warm"]) == "reflective, warm"


def test_as_text_passes_strings_through():
    assert _as_text("calm") == "calm"


def test_as_text_handles_none_and_scalars():
    assert _as_text(None) == ""
    assert _as_text(3) == "3"


def test_as_text_drops_empty_parts():
    assert _as_text(["a", "", None, "b"]) == "a, b"


def test_as_text_list_wraps_a_bare_string():
    assert _as_text_list("fishing") == ["fishing"]


def test_as_text_list_normalises_members():
    assert _as_text_list(["a", None, "", "b"]) == ["a", "b"]
    assert _as_text_list(None) == []


def test_nested_lists_still_flatten():
    assert _as_text([["a", "b"], "c"]) == "a, b, c"
