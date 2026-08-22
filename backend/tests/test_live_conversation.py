"""The Gemini bridge's own loop: does a call survive its first answer?

The real path needs credentials and the `google-genai` SDK, so what stands in
here is a fake session with the one SDK behaviour that shaped the bridge: its
`receive()` generator covers a *single* model turn and returns at
`turn_complete`. A bridge that iterates it once answers the first question and
then listens forever without replying, which is exactly what a user reports as
"it only answers once".
"""

from __future__ import annotations

import asyncio
from types import SimpleNamespace

from app.core.config import get_settings
from app.services.live import GeminiLiveSession

# -- the stand-in ---------------------------------------------------------


def audio(pcm: bytes) -> SimpleNamespace:
    return SimpleNamespace(data=pcm, server_content=None, tool_call=None)


def said(text: str = "", *, done: bool = False) -> SimpleNamespace:
    content = SimpleNamespace(
        input_transcription=None,
        output_transcription=SimpleNamespace(text=text) if text else None,
        interrupted=False,
        turn_complete=done,
    )
    return SimpleNamespace(data=None, server_content=content, tool_call=None)


def tool(query: str, call_id: str = "c1") -> SimpleNamespace:
    call = SimpleNamespace(id=call_id, name="recall_memories", args={"query": query})
    return SimpleNamespace(
        data=None, server_content=None, tool_call=SimpleNamespace(function_calls=[call])
    )


class FakeLive:
    """The SDK's session, reduced to its turn-scoped `receive()`."""

    def __init__(self, turns: list[list[SimpleNamespace]]) -> None:
        self._turns = list(turns)
        self.tool_responses: list = []
        self.sent: list[tuple[str, object]] = []

    def receive(self):
        messages = self._turns.pop(0) if self._turns else []

        async def _turn():
            for message in messages:
                yield message

        return _turn()

    async def send_tool_response(self, function_responses) -> None:
        self.tool_responses.extend(function_responses)

    async def send_realtime_input(self, audio) -> None:
        self.sent.append(("audio", audio.data))

    async def send_client_content(self, turns, turn_complete) -> None:
        self.sent.append(("text", turns))


FAKE_TYPES = SimpleNamespace(
    FunctionResponse=lambda **kw: kw,
    Blob=lambda data, mime_type: SimpleNamespace(data=data, mime_type=mime_type),
)


def bridge() -> GeminiLiveSession:
    return GeminiLiveSession("alice", None, get_settings())


def drained(session: GeminiLiveSession) -> list[tuple[str, bytes | dict]]:
    events = []
    while not session._events.empty():
        event = session._events.get_nowait()
        if event is None:
            break
        events.append((event.kind, event.audio or event.payload))
    return events


# -- what it has to do ----------------------------------------------------


async def test_the_call_keeps_answering_after_the_first_turn():
    """The regression: two questions, two answers, on one open session."""
    live = FakeLive(
        [
            [audio(b"\x01\x02"), said("Max.", done=True)],
            [audio(b"\x03\x04"), said("In 2019.", done=True)],
            [],  # the socket finally goes
        ]
    )
    session = bridge()

    await session._pump_down(live, FAKE_TYPES)

    kinds = [kind for kind, _ in drained(session)]
    assert kinds == [
        "audio",
        "output_transcript",
        "turn_complete",
        "audio",
        "output_transcript",
        "turn_complete",
    ], "the second turn has to reach the client too"


async def test_a_silent_receive_ends_the_pump_instead_of_spinning():
    """A turn that yields nothing is a dead socket, not a quiet model."""
    session = bridge()
    await asyncio.wait_for(session._pump_down(FakeLive([[]]), FAKE_TYPES), timeout=2)


async def test_memories_are_recalled_mid_turn_and_cited(make_recording):
    """The tool call is answered inside the turn, and the client is told what the
    answer drew on — a spoken answer still has to show its sources."""
    make_recording("alice", "We adopted a golden retriever puppy named Max.")
    live = FakeLive([[tool("the puppy's name"), said("Max.", done=True)], []])
    session = bridge()

    await session._pump_down(live, FAKE_TYPES)

    assert live.tool_responses, "the model was left waiting on its own tool call"
    answered = live.tool_responses[0]
    assert answered["name"] == "recall_memories"
    assert answered["response"]["memories"], "the recall found nothing to ground on"

    cited = [payload for kind, payload in drained(session) if kind == "citations"]
    assert cited and cited[0]["citations"]


async def test_hanging_up_ends_the_call_rather_than_leaving_a_pump_running():
    """`audio_end` stops the upward pump; the downward one must not be left
    holding an open Gemini session, which bills for as long as it is held."""
    session = bridge()
    never = FakeLive([])
    never.receive = _never_returns  # a live socket with nothing to say yet

    session._outbox.put_nowait(None)  # what `aclose` sends when the client hangs up
    await asyncio.wait_for(session._converse(never, FAKE_TYPES), timeout=2)


def _never_returns():
    async def _turn():
        await asyncio.Event().wait()
        yield  # pragma: no cover - unreachable, and only here to make this a generator

    return _turn()
