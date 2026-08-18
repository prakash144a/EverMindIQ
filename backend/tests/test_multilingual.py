"""Multilingual plumbing.

The mock embedder is lexical (not multilingual), so true cross-lingual retrieval (English query ->
Tamil memory) is validated in real mode with the multilingual embedding model. Here we verify the
pipeline preserves the original language/script, tags the language, and that same-language retrieval
works — plus that the answer-language preference is honored.
"""

from tests.conftest import auth


def test_native_language_transcript_is_preserved_and_tagged(make_recording):
    rec = make_recording(
        "kavya",
        "இன்று நான் மகனுடன் கோயிலுக்கு சென்றேன்.",  # Tamil: went to the temple with my son today
        language="ta",
    )
    assert rec["language"] == "ta"
    assert "கோயிலுக்கு" in rec["transcript"]  # original script retained


def test_same_language_retrieval(make_recording, client):
    make_recording("kavya", "आज मैंने पहली बार साइकिल चलाना सीखा।", language="hi")  # learned to cycle
    r = client.post(
        "/chat",
        json={"question": "साइकिल चलाना सीखा?"},
        headers=auth("kavya"),
    )
    assert r.json()["citations"]


def test_typed_native_language_memory_keeps_its_script(make_text_memory):
    """A typed memory arrives with no language at all — enrichment supplies it.

    This matters more for writing than for speaking: someone typing in Tamil has
    no transcription step to detect the language for them.
    """
    rec = make_text_memory("kavya", "இன்று நான் மகனுடன் கோயிலுக்கு சென்றேன்.")
    assert rec["language"] == "ta"
    assert "கோயிலுக்கு" in rec["transcript"]
    # Not English, so no English copy is fabricated.
    assert rec["transcript_en"] == ""


def test_typed_memory_retrieval_in_the_same_language(make_text_memory, client):
    make_text_memory("kavya", "आज मैंने पहली बार साइकिल चलाना सीखा।")
    r = client.post("/chat", json={"question": "साइकिल चलाना सीखा?"}, headers=auth("kavya"))
    assert r.json()["citations"]


def test_answer_language_preference_is_applied(make_recording, client):
    make_recording("kavya", "We visited Paris and saw the Eiffel Tower.")
    r = client.post(
        "/chat",
        json={"question": "Where did we visit?", "answer_language": "en"},
        headers=auth("kavya"),
    )
    # Mock generator prefixes the forced language; real Gemini answers natively in it.
    assert r.json()["answer"].startswith("[en]")
