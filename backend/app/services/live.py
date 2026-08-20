"""Talk-to-AI voice: the bridge between the app's WebSocket and Gemini Live.

The app streams raw microphone PCM up this bridge and plays the PCM that comes
back, so the model hears the user directly and answers in its own voice. What
that buys over the on-device speech recognition it replaces is **language**: a
phone's recognizer and its text-to-speech voice are chosen per locale and were
reading every answer back in English, to users whose memories are in Tamil or
Hindi. Gemini hears and speaks those natively, in one model, over one socket.

The user's memories reach the model as a **tool**, not as a prompt stuffed with
context up front. A spoken conversation has no single question to retrieve for —
it wanders, doubles back, and asks follow-ups — so the model calls
``recall_memories`` whenever it needs something and we answer from the same
retrieval path the text Recall screen uses (``pipeline.rag.retrieve``). Anything
it recalls is also reported to the client as citations, so a spoken answer can
still show its sources.

Mock mode has no speech recognition and no voice, so it cannot fake a real audio
turn. It does the honest thing instead: it reports ``audio: False`` at handshake
and the app says voice needs the cloud backend, rather than showing a listening
screen that will never answer. It still implements the whole frame protocol —
text turn in, synthesized waveform out — so the transport is exercisable end to
end in tests without credentials.
"""

from __future__ import annotations

import asyncio
import math
import struct
from collections.abc import AsyncIterator
from dataclasses import dataclass, field

from app.core.config import Settings, get_settings
from app.core.entitlements import max_voice_session_seconds, tier_for
from app.models.chat import ChatRequest
from app.pipeline.rag import retrieve
from app.services.firestore import get_repository

# The app records at 16 kHz mono and plays back at 24 kHz mono, both PCM16
# little-endian. These are Gemini Live's own rates, not a choice of ours;
# the client hardcodes the same two numbers.
INPUT_SAMPLE_RATE = 16_000
OUTPUT_SAMPLE_RATE = 24_000

# ~100 ms of output audio per frame. Small enough that playback starts promptly,
# large enough that a turn is not thousands of WebSocket frames.
_OUTPUT_FRAME_SAMPLES = OUTPUT_SAMPLE_RATE // 10

_RECALL_TOOL = "recall_memories"

_SYSTEM_INSTRUCTION = (
    "You are the voice of a personal memory journal, talking with the person whose "
    "memories they are. You are speaking aloud, so keep replies short and "
    "conversational — a sentence or two — and never read out lists, markdown, dates "
    "in ISO form, or anything that only makes sense on a screen.\n\n"
    f"Whenever the person refers to their own life, call {_RECALL_TOOL} before "
    "answering, and ground what you say only in what it returns. If it returns "
    "nothing, say plainly that you could not find that memory — never invent an "
    "event, a name, or a date. You may answer small talk without the tool.\n\n"
    "Speak the language the person is speaking. If they switch language mid-"
    "conversation, switch with them. Their memories may be recorded in one "
    "language and asked about in another: answer in the language of the question, "
    "quoting their own words in the original when it matters."
)


@dataclass
class LiveEvent:
    """One frame's worth of something to forward to the client.

    ``kind`` is the wire discriminator: ``audio`` carries binary PCM in
    ``audio``; everything else carries JSON in ``payload``.
    """

    kind: str
    audio: bytes = b""
    payload: dict = field(default_factory=dict)


def supports_audio(settings: Settings | None = None) -> bool:
    """Whether this deployment can hold a real spoken conversation."""
    return not (settings or get_settings()).effective_mock


def _recall(uid: str, query: str, journal_id: str | None) -> tuple[dict, list[dict]]:
    """Run one memory search on behalf of the model.

    Returns what the model is told, and the citations the client is shown. The
    two differ on purpose: the model gets dated text to reason over, the client
    gets ids it can open the memory from.
    """
    found = retrieve(uid, ChatRequest(question=query, journal_id=journal_id))
    if not found.context_blocks:
        return ({"memories": [], "note": "No matching memories were found."}, [])
    return (
        {"memories": found.context_blocks, **found.scope},
        [c.model_dump(mode="json") for c in found.citations],
    )


class LiveSession:
    """A live voice conversation, from the router's point of view.

    Subclasses differ only in what sits on the far side: Gemini, or a synthetic
    stand-in. The router talks to both the same way.
    """

    async def start(self) -> None:
        raise NotImplementedError

    async def send_audio(self, pcm: bytes) -> None:
        raise NotImplementedError

    async def send_text(self, text: str) -> None:
        raise NotImplementedError

    def events(self) -> AsyncIterator[LiveEvent]:
        raise NotImplementedError

    async def aclose(self) -> None:
        raise NotImplementedError


class _QueuedSession(LiveSession):
    """Shared plumbing: an event queue the router drains until the far side ends,
    and the clock that ends the call when the caller's tier runs out of time."""

    def __init__(self, uid: str, journal_id: str | None, max_seconds: int = 0) -> None:
        self.uid = uid
        self.journal_id = journal_id
        # 0 disables the limit. Enforced here rather than in the router because
        # what it protects is the far side of *this* object: an open Gemini Live
        # socket bills for as long as it is held, whatever the client does.
        self.max_seconds = max_seconds
        self._events: asyncio.Queue[LiveEvent | None] = asyncio.Queue()
        self._deadline: asyncio.Task | None = None

    def _emit(self, kind: str, pcm: bytes = b"", **payload: object) -> None:
        self._events.put_nowait(LiveEvent(kind, pcm, dict(payload)))

    def _arm_deadline(self) -> None:
        """Start the hang-up timer. Called once the conversation is actually live,
        so a slow handshake is not charged against the caller's minutes."""
        if self.max_seconds > 0 and self._deadline is None:
            self._deadline = asyncio.create_task(self._expire())

    async def _expire(self) -> None:
        await asyncio.sleep(self.max_seconds)
        # Announced before closing, and as its own frame rather than an `error`:
        # running out of time is the plan working, and the app says so in those
        # words instead of apologising for a failure.
        self._emit("limit_reached", limit_sec=self.max_seconds)
        # Cleared first — `aclose` cancels this task, and cancelling the task
        # that is running is how you lose the close it was in the middle of.
        self._deadline = None
        await self.aclose()

    def _cancel_deadline(self) -> None:
        task, self._deadline = self._deadline, None
        if task is not None:
            task.cancel()

    async def events(self) -> AsyncIterator[LiveEvent]:
        while True:
            event = await self._events.get()
            if event is None:
                return
            yield event


def _synth_speech(text: str) -> bytes:
    """A placeholder waveform standing in for a spoken answer, in mock mode.

    Not speech, and not pretending to be: a soft tone whose length tracks the
    answer's. It exists so the client's playback path — frame sizes, sample
    rate, buffering, the barge-in that stops it — is exercisable with no cloud
    and no credentials, which is the only part of a voice turn a mock can
    honestly stand in for.
    """
    seconds = min(6.0, max(0.5, len(text) / 15))
    total = int(OUTPUT_SAMPLE_RATE * seconds)
    samples = bytearray()
    for n in range(total):
        # A quiet 220 Hz tone, faded in and out so it does not click.
        envelope = min(1.0, n / 2000, (total - n) / 2000)
        value = int(6000 * envelope * math.sin(2 * math.pi * 220 * n / OUTPUT_SAMPLE_RATE))
        samples += struct.pack("<h", value)
    return bytes(samples)


class MockLiveSession(_QueuedSession):
    """Offline stand-in: a text turn in, a real RAG answer and a tone out."""

    def __init__(self, uid: str, journal_id: str | None, max_seconds: int = 0) -> None:
        super().__init__(uid, journal_id, max_seconds)
        self.audio_bytes_in = 0

    async def start(self) -> None:
        self._emit("ready", audio=False, reason="mock", limit_sec=self.max_seconds)
        self._arm_deadline()

    async def send_audio(self, pcm: bytes) -> None:
        # Counted, not recognized. Mock mode has no transcription, and inventing
        # a transcript here would make a broken client look like a working one.
        self.audio_bytes_in += len(pcm)

    async def send_text(self, text: str) -> None:
        question = text.strip()
        if not question:
            self._emit("error", message="expected a non-empty turn")
            return
        self._emit("input_transcript", text=question)
        response, citations = await asyncio.to_thread(
            _mock_turn, self.uid, question, self.journal_id
        )
        if citations:
            self._emit("citations", citations=citations)
        self._emit("output_transcript", text=response)
        audio = _synth_speech(response)
        frame = _OUTPUT_FRAME_SAMPLES * 2  # 2 bytes per sample
        for start in range(0, len(audio), frame):
            self._emit("audio", audio[start : start + frame])
        self._emit("turn_complete")

    async def aclose(self) -> None:
        self._cancel_deadline()
        self._events.put_nowait(None)


def _mock_turn(uid: str, question: str, journal_id: str | None) -> tuple[str, list[dict]]:
    """The mock's whole turn: the same RAG the text path runs, answered as text."""
    from app.pipeline.rag import answer_question

    resp = answer_question(uid, ChatRequest(question=question, journal_id=journal_id))
    return resp.answer, [c.model_dump(mode="json") for c in resp.citations]


class GeminiLiveSession(_QueuedSession):  # pragma: no cover - real path
    """The real bridge: a Gemini Live session, fed by the client's microphone.

    One task owns the connection for its whole life, because the SDK's session
    is only valid inside its context manager. Outbound frames reach that task
    through a queue rather than touching the session from the router's task.
    """

    def __init__(
        self, uid: str, journal_id: str | None, settings: Settings, max_seconds: int = 0
    ) -> None:
        super().__init__(uid, journal_id, max_seconds)
        self.settings = settings
        self._outbox: asyncio.Queue[tuple[str, object] | None] = asyncio.Queue()
        self._task: asyncio.Task | None = None

    async def start(self) -> None:
        self._task = asyncio.create_task(self._run())

    async def send_audio(self, pcm: bytes) -> None:
        self._outbox.put_nowait(("audio", pcm))

    async def send_text(self, text: str) -> None:
        self._outbox.put_nowait(("text", text))

    async def aclose(self) -> None:
        self._cancel_deadline()
        self._outbox.put_nowait(None)
        if self._task:
            try:
                await asyncio.wait_for(self._task, timeout=5)
            except (TimeoutError, asyncio.CancelledError):
                self._task.cancel()
        self._events.put_nowait(None)

    def _config(self):
        from google.genai import types

        recall = types.FunctionDeclaration(
            name=_RECALL_TOOL,
            description=(
                "Search the person's own recorded memories. Call this before answering "
                "anything about their life, and answer only from what it returns."
            ),
            parameters=types.Schema(
                type=types.Type.OBJECT,
                properties={
                    "query": types.Schema(
                        type=types.Type.STRING,
                        description="What to look for, in the person's own words.",
                    )
                },
                required=["query"],
            ),
        )
        return types.LiveConnectConfig(
            response_modalities=["AUDIO"],
            system_instruction=types.Content(parts=[types.Part(text=_SYSTEM_INSTRUCTION)]),
            tools=[types.Tool(function_declarations=[recall])],
            # Both directions transcribed: the client shows what it heard and
            # what it said, and a spoken answer that was misheard is otherwise
            # impossible for the user to diagnose.
            input_audio_transcription=types.AudioTranscriptionConfig(),
            output_audio_transcription=types.AudioTranscriptionConfig(),
        )

    async def _run(self) -> None:
        from google import genai
        from google.genai import types

        client = genai.Client(
            vertexai=True,
            project=self.settings.gcp_project,
            location=self.settings.gcp_region,
        )
        try:
            async with client.aio.live.connect(
                model=self.settings.model_live, config=self._config()
            ) as session:
                self._emit("ready", audio=True, limit_sec=self.max_seconds)
                self._arm_deadline()
                await asyncio.gather(
                    self._pump_up(session, types),
                    self._pump_down(session, types),
                )
        except Exception as exc:  # the socket is the feature; never fail silently
            self._emit("error", message=f"live session ended: {exc}")
        finally:
            self._events.put_nowait(None)

    async def _pump_up(self, session, types) -> None:
        """Client -> Gemini, until the client hangs up."""
        while True:
            item = await self._outbox.get()
            if item is None:
                return
            kind, value = item
            if kind == "audio":
                await session.send_realtime_input(
                    audio=types.Blob(
                        data=value, mime_type=f"audio/pcm;rate={INPUT_SAMPLE_RATE}"
                    )
                )
            elif kind == "text":
                await session.send_client_content(
                    turns=types.Content(role="user", parts=[types.Part(text=str(value))]),
                    turn_complete=True,
                )

    async def _pump_down(self, session, types) -> None:
        """Gemini -> client, translating the SDK's message shapes to our frames."""
        async for message in session.receive():
            data = getattr(message, "data", None)
            if data:
                self._emit("audio", data)

            content = getattr(message, "server_content", None)
            if content is not None:
                heard = getattr(content, "input_transcription", None)
                if heard is not None and getattr(heard, "text", ""):
                    self._emit("input_transcript", text=heard.text)
                spoken = getattr(content, "output_transcription", None)
                if spoken is not None and getattr(spoken, "text", ""):
                    self._emit("output_transcript", text=spoken.text)
                if getattr(content, "interrupted", False):
                    # The user talked over the answer: tell the client to drop
                    # whatever it has buffered, or it keeps speaking a reply
                    # the model has already abandoned.
                    self._emit("interrupted")
                if getattr(content, "turn_complete", False):
                    self._emit("turn_complete")

            tool_call = getattr(message, "tool_call", None)
            if tool_call is not None:
                await self._answer_tool_call(session, types, tool_call)

    async def _answer_tool_call(self, session, types, tool_call) -> None:
        responses = []
        for call in getattr(tool_call, "function_calls", None) or []:
            if call.name != _RECALL_TOOL:
                responses.append(
                    types.FunctionResponse(
                        id=call.id, name=call.name, response={"error": "unknown tool"}
                    )
                )
                continue
            query = (call.args or {}).get("query", "")
            result, citations = await asyncio.to_thread(
                _recall, self.uid, query, self.journal_id
            )
            if citations:
                self._emit("citations", citations=citations)
            responses.append(
                types.FunctionResponse(id=call.id, name=call.name, response=result)
            )
        if responses:
            await session.send_tool_response(function_responses=responses)


def open_live_session(uid: str, journal_id: str | None = None) -> LiveSession:
    """The voice session for this deployment: Gemini in real mode, a stand-in in mock.

    Resolves the caller's own time limit here rather than taking it from the
    router, so no caller of this factory can open an unbounded conversation by
    forgetting to pass one.
    """
    settings = get_settings()
    max_seconds = max_voice_session_seconds(tier_for(get_repository(), uid))
    if settings.effective_mock:
        return MockLiveSession(uid, journal_id, max_seconds)
    return GeminiLiveSession(  # pragma: no cover - real path
        uid, journal_id, settings, max_seconds
    )
