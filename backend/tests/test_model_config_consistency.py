"""Every place a model id is written must agree.

No config file reaches production — the Dockerfile copies only `pyproject.toml`
and `app/` — so the deployed service takes its models from the Cloud Run env vars
Terraform sets, falling back to the code defaults. Terraform reads them out of
`config/production.env`, which is gitignored, so `production.env.example` is the
committed stand-in for a fresh clone or CI.

That is four copies of the same three ids. The last time they drifted the symptom
was silent: `VOICEIQ_MODEL_LIVE` was simply absent from `infra/main.tf`, so the
service fell back to an alias Vertex does not publish and every voice call would
have failed to connect. These tests make that drift loud instead.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from app.core.config import Settings

_REPO = Path(__file__).resolve().parents[2]
_PROD_EXAMPLE = _REPO / "backend" / "config" / "production.env.example"
_LOCAL_ENV = _REPO / "backend" / "config" / "local.env"
_VARIABLES_TF = _REPO / "infra" / "variables.tf"

# setting name -> (env var in the config files, terraform variable in variables.tf)
_SLOTS = {
    "model_reasoning": ("VOICEIQ_MODEL_REASONING", "model_reasoning"),
    "model_live": ("VOICEIQ_MODEL_LIVE", "model_live"),
    "model_embedding": ("VOICEIQ_MODEL_EMBEDDING", "model_embedding"),
}


def _code_default(field: str) -> str:
    """The default baked into the image, read without letting a local .env win."""
    return str(Settings.model_fields[field].default)


def _file_value(path: Path, key: str) -> str | None:
    for line in path.read_text(encoding="utf-8").splitlines():
        name, _, value = line.partition("=")
        if name.strip() == key:
            return value.strip()
    return None


def _terraform_default(name: str) -> str | None:
    text = _VARIABLES_TF.read_text(encoding="utf-8")
    block = re.search(
        rf'variable\s+"{re.escape(name)}"\s*\{{(.*?)\n\}}', text, re.DOTALL
    )
    if not block:
        return None
    default = re.search(r'default\s*=\s*"([^"]*)"', block.group(1))
    return default.group(1) if default else None


@pytest.mark.parametrize("field", sorted(_SLOTS))
def test_production_example_matches_code_default(field: str) -> None:
    """The committed stand-in is what Terraform falls back to in CI."""
    env_key, _ = _SLOTS[field]
    assert _file_value(_PROD_EXAMPLE, env_key) == _code_default(field), (
        f"{env_key} in config/production.env.example disagrees with "
        f"Settings.{field}. Whichever is right, make them match."
    )


@pytest.mark.parametrize("field", sorted(_SLOTS))
def test_local_profile_matches_code_default(field: str) -> None:
    """Kept in step so the two profiles can be diffed for what really differs."""
    env_key, _ = _SLOTS[field]
    assert _file_value(_LOCAL_ENV, env_key) == _code_default(field), (
        f"{env_key} in config/local.env disagrees with Settings.{field}."
    )


@pytest.mark.parametrize("field", sorted(_SLOTS))
def test_terraform_matches_code_default(field: str) -> None:
    if not _VARIABLES_TF.exists():  # pragma: no cover - infra/ absent in some checkouts
        pytest.skip("infra/variables.tf not present")
    _, tf_name = _SLOTS[field]
    assert _terraform_default(tf_name) == _code_default(field), (
        f'variable "{tf_name}" in infra/variables.tf disagrees with '
        f"Settings.{field}. Cloud Run takes its value from Terraform, so this is "
        "the copy that decides what production actually runs."
    )


@pytest.mark.parametrize("field", sorted(_SLOTS))
def test_no_latest_aliases(field: str) -> None:
    """No `-latest` alias is published on Vertex; one here fails the call outright."""
    assert not _code_default(field).endswith("latest")


def test_terraform_passes_every_slot_to_cloud_run() -> None:
    """A slot declared but never wired reaches the service as its code default.

    That is exactly how the live model went missing: a value is only worth
    anything if `main.tf` actually puts it in the container's environment. The
    assertion is on the `env` block specifically — matching the name anywhere in
    the file would also be satisfied by the `locals` fallback, which proves
    nothing about what Cloud Run receives.
    """
    main_tf = _REPO / "infra" / "main.tf"
    if not main_tf.exists():  # pragma: no cover - infra/ absent in some checkouts
        pytest.skip("infra/main.tf not present")
    text = main_tf.read_text(encoding="utf-8")
    for env_key, tf_name in _SLOTS.values():
        block = re.search(
            rf'env\s*\{{\s*name\s*=\s*"{re.escape(env_key)}"\s*value\s*=\s*([^\s]+)',
            text,
        )
        assert block, f"{env_key} is never set on Cloud Run"
        assert block.group(1) == f"local.{tf_name}", (
            f"{env_key} is wired to {block.group(1)}, not local.{tf_name}, so it "
            "does not follow config/production.env"
        )


def test_terraform_sources_models_from_the_env_file() -> None:
    """The whole point: production reads the file a developer actually edits."""
    main_tf = _REPO / "infra" / "main.tf"
    if not main_tf.exists():  # pragma: no cover - infra/ absent in some checkouts
        pytest.skip("infra/main.tf not present")
    text = main_tf.read_text(encoding="utf-8")
    assert "config/production.env" in text, (
        "Terraform no longer reads backend/config/production.env"
    )
    assert "VOICEIQ_MODEL_" in text


def test_production_profile_has_no_alias_models() -> None:
    """Guard the real production profile, since it is what actually deploys."""
    env = _REPO / "backend" / "config" / "production.env"
    if not env.exists():  # pragma: no cover - gitignored; absent in CI
        pytest.skip("config/production.env is machine-local")
    for line in env.read_text(encoding="utf-8").splitlines():
        key, _, value = line.partition("=")
        if key.strip().startswith("VOICEIQ_MODEL_"):
            assert not value.strip().endswith("latest"), (
                f"{key.strip()} is a -latest alias, which Vertex does not "
                "publish; this would now be deployed to production"
            )


def test_production_profile_is_not_committable() -> None:
    """It holds a live Azure credential and this repository is public.

    Cheap to assert, expensive to get wrong: the file only stays private for as
    long as both ignore lists keep naming it.
    """
    gitignore = (_REPO / ".gitignore").read_text(encoding="utf-8")
    assert "backend/config/production.env" in gitignore, (
        "config/production.env is no longer gitignored, and it holds a secret"
    )
    gcloudignore = (_REPO / "backend" / ".gcloudignore").read_text(encoding="utf-8")
    assert "config/" in gcloudignore, (
        "config/ is no longer excluded from the Cloud Build context"
    )


def test_acs_credential_is_mounted_from_secret_manager() -> None:
    """The connection string must never be a literal env value on Cloud Run.

    A literal is readable in the console, in `gcloud run describe`, and in deploy
    logs; a secret reference is not. This asserts the shape, because the
    difference is one nested block and easy to lose in an edit.
    """
    main_tf = _REPO / "infra" / "main.tf"
    if not main_tf.exists():  # pragma: no cover - infra/ absent in some checkouts
        pytest.skip("infra/main.tf not present")
    text = main_tf.read_text(encoding="utf-8")
    block = re.search(
        r'name\s*=\s*"VOICEIQ_ACS_CONNECTION_STRING"(.*?)\n\s{6}\}',
        text,
        re.DOTALL,
    )
    assert block, "VOICEIQ_ACS_CONNECTION_STRING is not set on Cloud Run"
    assert "secret_key_ref" in block.group(1), (
        "the ACS connection string is set as a literal value; mount it from "
        "Secret Manager instead"
    )
    assert "value =" not in block.group(1), "the credential is inlined as a literal"


def test_empty_acs_credential_cannot_be_published() -> None:
    """production.env is gitignored, so the fallback file has a blank credential.

    Without the precondition, applying from a fresh clone would publish an empty
    secret version and silently break sign-in email.
    """
    main_tf = _REPO / "infra" / "main.tf"
    if not main_tf.exists():  # pragma: no cover - infra/ absent in some checkouts
        pytest.skip("infra/main.tf not present")
    text = main_tf.read_text(encoding="utf-8")
    assert "precondition" in text, "an empty ACS credential can still be published"
    assert 'acs_connection_string != ""' in text

    assert _file_value(_PROD_EXAMPLE, "VOICEIQ_ACS_CONNECTION_STRING") == "", (
        "production.env.example is committed; it must never carry a real credential"
    )
    assert "accesskey" not in _PROD_EXAMPLE.read_text(encoding="utf-8").lower()
