"""Gemini-backed language tasks: transcription, enrichment, and RAG answer generation.

Real mode calls the latest GA Gemini model (slot configured in settings). Mock mode returns
deterministic results so the pipeline and API are fully exercisable offline. A small seed registry
lets tests/local dev attach a known transcript to an uploaded audio path.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

from app.core.config import Settings, get_settings
from app.core.media import content_type_for_path

# audio_path -> (transcript, language). Seeded by tests / a dev endpoint in mock mode.
_TRANSCRIPT_SEED: dict[str, tuple[str, str]] = {}


def seed_transcript(audio_path: str, transcript: str, language: str = "en") -> None:
    """Register a transcript for a mock audio object so ingestion can 'transcribe' it."""
    _TRANSCRIPT_SEED[audio_path] = (transcript, language)


@dataclass
class Enrichment:
    title: str
    summary: str
    tags: list[str] = field(default_factory=list)
    people: list[str] = field(default_factory=list)
    places: list[str] = field(default_factory=list)
    mood: str = ""
    is_milestone: bool = False
    transcript_en: str = ""


def _as_text(value: object) -> str:
    """Coerce an LLM JSON value to text.

    The model is asked for a string but does not always oblige — ``"mood":
    ["reflective", "warm"]`` is a common shape. ``Recording`` is a Pydantic model
    without ``validate_assignment``, so assigning a list to a ``str`` field is
    silently accepted and only blows up later in the client's JSON parsing.
    """
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    if isinstance(value, (list, tuple)):
        return ", ".join(p for p in (_as_text(v) for v in value) if p)
    return str(value)


def _as_text_list(value: object) -> list[str]:
    """Coerce an LLM JSON value to a list of strings, tolerating a bare string."""
    if value is None:
        return []
    if isinstance(value, (list, tuple)):
        return [p for p in (_as_text(v) for v in value) if p]
    single = _as_text(value)
    return [single] if single else []


_SENTENCE_RE = re.compile(r"(?<=[.!?।])\s+")
_CAP_RE = re.compile(r"\b([A-Z][a-z]{2,})\b")
_MILESTONE_HINTS = ("born", "wedding", "married", "graduated", "promotion", "first ", "milestone")


class GeminiService:
    def __init__(self, settings: Settings | None = None) -> None:
        self.settings = settings or get_settings()

    # -- transcription -----------------------------------------------------
    def transcribe(self, audio_path: str, audio_bytes: bytes) -> tuple[str, str]:
        """Return (transcript, language). Language auto-detected; original script preserved."""
        if self.settings.effective_mock:
            if audio_path in _TRANSCRIPT_SEED:
                return _TRANSCRIPT_SEED[audio_path]
            # No seed and mock mode can't run real speech-to-text; return a clear placeholder so
            # the recorded memory still flows through enrich/index and appears in the app.
            return (
                "Voice memo captured (mock mode has no speech-to-text; "
                "run in cloud mode for a real transcript).",
                "en",
            )
        return self._gemini_transcribe(  # pragma: no cover - real path
            audio_bytes, content_type_for_path(audio_path)
        )

    # -- enrichment --------------------------------------------------------
    def enrich(self, transcript: str, language: str, answer_language: str) -> Enrichment:
        if self.settings.effective_mock:
            return self._mock_enrich(transcript, language)
        return self._gemini_enrich(transcript, language, answer_language)  # pragma: no cover

    # -- RAG generation ----------------------------------------------------
    def answer(self, question: str, context_blocks: list[str], answer_language: str) -> str:
        if self.settings.effective_mock:
            return self._mock_answer(question, context_blocks, answer_language)
        return self._gemini_answer(question, context_blocks, answer_language)  # pragma: no cover

    def summarize_range(self, blocks: list[str], answer_language: str) -> tuple[str, list[str]]:
        """Return (summary, themes) for an insights range."""
        if self.settings.effective_mock:
            return self._mock_summarize(blocks)
        return self._gemini_summarize(blocks, answer_language)  # pragma: no cover

    # ==================================================================
    # Mock implementations (deterministic)
    # ==================================================================
    def _mock_enrich(self, transcript: str, language: str) -> Enrichment:
        text = transcript.strip()
        sentences = _SENTENCE_RE.split(text) if text else []
        first = sentences[0] if sentences else text
        title = self._mock_title(text)
        summary = first[:200]
        caps = sorted(set(_CAP_RE.findall(text)))
        lowered = text.lower()
        return Enrichment(
            title=title,
            summary=summary,
            tags=sorted({w for w in re.findall(r"\w{5,}", lowered)})[:5],
            people=caps[:5],
            places=[],
            mood="",
            is_milestone=any(h in lowered for h in _MILESTONE_HINTS),
            transcript_en=text if language.startswith("en") else "",
        )

    @staticmethod
    def _mock_title(text: str) -> str:
        """A readable stand-in title; the real path gets one from the LLM."""
        if not text:
            return "Untitled moment"
        if text.startswith("Voice memo captured"):
            return "Voice memo"
        words = text.split()
        title = " ".join(words[:6]).rstrip(".,;:!?")
        if len(words) > 6:
            title += "…"
        return title[:1].upper() + title[1:]

    def _mock_answer(self, question: str, context_blocks: list[str], answer_language: str) -> str:
        if not context_blocks:
            return "I couldn't find any memories related to that yet."
        joined = " ".join(b.replace("\n", " ") for b in context_blocks[:3])
        prefix = ""
        if answer_language and answer_language != "auto":
            prefix = f"[{answer_language}] "
        return (
            f"{prefix}Based on your memories: {joined[:400]} "
            f"(You asked: \"{question.strip()}\".)"
        )

    def _mock_summarize(self, blocks: list[str]) -> tuple[str, list[str]]:
        if not blocks:
            return ("No recordings in this period.", [])
        summary = f"You captured {len(blocks)} moment(s). " + " ".join(
            b.replace("\n", " ")[:80] for b in blocks[:3]
        )
        words = re.findall(r"\w{5,}", " ".join(blocks).lower())
        freq: dict[str, int] = {}
        for w in words:
            freq[w] = freq.get(w, 0) + 1
        themes = [w for w, _ in sorted(freq.items(), key=lambda kv: -kv[1])[:5]]
        return (summary[:600], themes)

    # ==================================================================
    # Real implementations (Gemini) — not exercised in mock tests.
    # ==================================================================
    def _client(self):  # pragma: no cover - real path
        from google import genai

        return genai.Client(
            vertexai=True, project=self.settings.gcp_project, location=self.settings.gcp_region
        )

    def _gemini_transcribe(  # pragma: no cover
        self, audio_bytes: bytes, mime_type: str
    ) -> tuple[str, str]:
        from google.genai import types

        client = self._client()
        resp = client.models.generate_content(
            model=self.settings.model_reasoning,
            contents=[
                types.Part.from_bytes(data=audio_bytes, mime_type=mime_type),
                "Transcribe verbatim in the original language and script. Then on a final line "
                "output 'LANG: <bcp47>'.",
            ],
        )
        text = resp.text or ""
        lang = "en"
        m = re.search(r"LANG:\s*([\w-]+)\s*$", text)
        if m:
            lang = m.group(1)
            text = text[: m.start()].strip()
        return text, lang

    def _gemini_enrich(self, transcript, language, answer_language):  # pragma: no cover
        import json

        from google.genai import types

        client = self._client()
        resp = client.models.generate_content(
            model=self.settings.model_reasoning,
            contents=(
                "You are helping someone keep a personal memory journal. The transcript below "
                "is that person speaking about their own life — it is their memory, not a "
                "report about a third party.\n\n"
                "Return JSON with keys title, summary, tags, people, places, mood, "
                "is_milestone, transcript_en (English translation; empty if already English).\n"
                "- title: a short, specific, human title for this memory, 3-6 words, from the "
                "speaker's own perspective (e.g. \"Fishing trip with Dad\", \"The day I moved "
                "to Chennai\"). No quotes, no trailing punctuation, and never generic filler "
                "like \"Voice note\" or \"Recording\".\n"
                "- summary: 1-2 sentences in the FIRST PERSON, as the speaker would write it "
                "in their own diary (\"I went to...\", \"We spent the afternoon...\"). Never "
                "write \"the user\", \"the speaker\", \"they\", or any third-person narration.\n"
                "- is_milestone: true ONLY for a significant life event the person would want "
                "resurfaced years later — a birth, a death, a wedding or engagement, moving "
                "home, a new job, a graduation, a major first, a diagnosis or recovery, a "
                "landmark trip. False for ordinary days, routine updates, passing thoughts, "
                "and merely happy or pleasant moments. When in doubt, false.\n"
                f"- Write title and summary in this language: {answer_language}.\n\n"
                f"Transcript ({language}):\n{transcript}"
            ),
            config=types.GenerateContentConfig(response_mime_type="application/json"),
        )
        data = json.loads(resp.text or "{}")
        if not isinstance(data, dict):
            data = {}
        # Coerce every field: the model's JSON is untrusted input, and a wrong
        # shape here is stored verbatim and breaks the app's parsing later.
        return Enrichment(
            title=_as_text(data.get("title")),
            summary=_as_text(data.get("summary")),
            tags=_as_text_list(data.get("tags")),
            people=_as_text_list(data.get("people")),
            places=_as_text_list(data.get("places")),
            mood=_as_text(data.get("mood")),
            is_milestone=bool(data.get("is_milestone", False)),
            transcript_en=_as_text(data.get("transcript_en")),
        )

    def _gemini_answer(self, question, context_blocks, answer_language):  # pragma: no cover
        client = self._client()
        context = "\n\n".join(context_blocks)
        lang = "the language of the question" if answer_language == "auto" else answer_language
        resp = client.models.generate_content(
            model=self.settings.model_reasoning,
            contents=(
                f"You are the user's memory assistant. Answer in {lang}, grounded ONLY in these "
                f"memories; cite dates. If unknown, say so.\n\nMemories:\n{context}\n\n"
                f"Question: {question}"
            ),
        )
        return resp.text or ""

    def _gemini_summarize(self, blocks, answer_language):  # pragma: no cover
        import json

        from google.genai import types

        client = self._client()
        lang = "the user's language" if answer_language == "auto" else answer_language
        resp = client.models.generate_content(
            model=self.settings.model_reasoning,
            contents=(
                f"Summarize these memories in {lang}. Return JSON {{summary, themes[]}}.\n\n"
                + "\n\n".join(blocks)
            ),
            config=types.GenerateContentConfig(response_mime_type="application/json"),
        )
        data = json.loads(resp.text or "{}")
        return data.get("summary", ""), data.get("themes", [])


def get_gemini() -> GeminiService:
    return GeminiService()
