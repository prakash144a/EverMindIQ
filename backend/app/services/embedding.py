"""Text embeddings.

Real mode uses a Vertex AI **multilingual** embedding model (the load-bearing choice for
cross-lingual recall: an English query matches Tamil/Hindi/French memories).

Mock mode uses a deterministic hashing bag-of-words embedder. It is not multilingual, but it produces
real, normalized vectors with meaningful cosine similarity for same-language text, so the RAG
retrieval path is genuinely exercised and testable without network calls.
"""

from __future__ import annotations

import hashlib
import math
import re

from app.core.config import Settings, get_settings

_TOKEN_RE = re.compile(r"\w+", re.UNICODE)


def _tokenize(text: str) -> list[str]:
    return _TOKEN_RE.findall(text.lower())


def _hash_bucket(token: str, dim: int) -> int:
    digest = hashlib.md5(token.encode("utf-8")).digest()
    return int.from_bytes(digest[:4], "big") % dim


class Embedder:
    def __init__(self, settings: Settings | None = None) -> None:
        self.settings = settings or get_settings()
        self.dim = self.settings.embedding_dim

    def embed(self, text: str) -> list[float]:
        return self.embed_batch([text])[0]

    def embed_batch(self, texts: list[str]) -> list[list[float]]:
        if self.settings.effective_mock:
            return [self._mock_embed(t) for t in texts]
        return self._vertex_embed(texts)  # pragma: no cover - real path

    # -- mock --------------------------------------------------------------
    def _mock_embed(self, text: str) -> list[float]:
        vec = [0.0] * self.dim
        for tok in _tokenize(text):
            vec[_hash_bucket(tok, self.dim)] += 1.0
        norm = math.sqrt(sum(v * v for v in vec))
        if norm == 0:
            return vec
        return [v / norm for v in vec]

    # -- real --------------------------------------------------------------
    def _vertex_embed(self, texts: list[str]) -> list[list[float]]:  # pragma: no cover
        from google import genai
        from google.genai import types

        client = genai.Client(vertexai=True, project=self.settings.gcp_project,
                              location=self.settings.gcp_region)
        # Force the output width to match the Firestore vector index (embedding_dim);
        # multilingual-embedding-002 is 768-d by default.
        resp = client.models.embed_content(
            model=self.settings.model_embedding,
            contents=texts,
            config=types.EmbedContentConfig(output_dimensionality=self.dim),
        )
        return [list(e.values) for e in resp.embeddings]


def cosine(a: list[float], b: list[float]) -> float:
    if not a or not b:
        return 0.0
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    if na == 0 or nb == 0:
        return 0.0
    return dot / (na * nb)


def get_embedder() -> Embedder:
    return Embedder()
