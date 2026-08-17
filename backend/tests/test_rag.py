from tests.conftest import auth


def test_rag_retrieves_relevant_memory_with_citation(make_recording, client):
    make_recording("alice", "On my birthday we ate chocolate cake and played guitar.")
    make_recording("alice", "I fixed a nasty database bug at work and felt relieved.")

    r = client.post(
        "/chat",
        json={"question": "What did I eat on my birthday?"},
        headers=auth("alice"),
    )
    assert r.status_code == 200
    body = r.json()
    assert body["citations"], "expected at least one cited memory"
    # The top citation should be the cake memory, not the database one.
    assert "cake" in body["citations"][0]["snippet"].lower()
    assert "chocolate" in body["answer"].lower()


def test_rag_returns_empty_when_no_memories(client):
    r = client.post("/chat", json={"question": "anything?"}, headers=auth("newuser"))
    assert r.status_code == 200
    assert r.json()["citations"] == []


def test_rag_is_isolated_per_user(make_recording, client):
    # Both memories share the word "vacation" so the (lexical) mock retriever has something to
    # match; per-user isolation must still ensure Bob only ever sees his own memory.
    make_recording("alice", "Alice went on vacation scuba diving in Bali.")
    make_recording("bob", "Bob went on vacation skiing in the Alps.")

    r = client.post(
        "/chat", json={"question": "Tell me about my vacation."}, headers=auth("bob")
    )
    citations = r.json()["citations"]
    assert citations
    # Bob must never see Alice's memories.
    for c in citations:
        rec = client.get(f"/recordings/{c['recording_id']}", headers=auth("bob"))
        assert rec.status_code == 200
        assert "scuba" not in rec.json()["recording"]["transcript"].lower()


def test_rag_date_filter(make_recording, client):
    # Both memories share "trip" (so the lexical mock matches both); the date filter must exclude
    # the out-of-range January one.
    make_recording("alice", "Trip to Japan for New Year.", event_date="2024-01-01")
    make_recording("alice", "Trip to the beach in summer.", event_date="2024-07-15")

    r = client.post(
        "/chat",
        json={
            "question": "Tell me about my trip.",
            "date_from": "2024-06-01",
            "date_to": "2024-12-31",
        },
        headers=auth("alice"),
    )
    citations = r.json()["citations"]
    assert citations
    for c in citations:
        assert c["event_date"] >= "2024-06-01"
