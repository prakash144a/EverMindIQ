# Offline install (org blocks files.pythonhosted.org)

If your machine can't reach the public PyPI CDN, download the packages once on a machine that **can**
reach PyPI, copy them in, and install with no network.

> ⚠️ **Platform matters.** Wheels are specific to OS + Python version. This project targets
> **Windows x64 + Python 3.12**. Download the wheels for *that* target, even if the machine you
> download on runs a different OS (see Step 1, Option B).

---

## Step 1 — Download wheels (on a machine WITH PyPI access)

`cd` into this `backend/` folder, then:

### Option A — the download machine is also Windows x64 + Python 3.12 (simplest)
```powershell
python -m pip download -r requirements.txt -d wheelhouse
```

### Option B — the download machine is a different OS (e.g. macOS/Linux)
Force the target platform so you get Windows wheels:
```bash
python -m pip download -r requirements.txt -d wheelhouse \
  --only-binary=:all: \
  --platform win_amd64 \
  --python-version 3.12 \
  --implementation cp \
  --abi cp312
```

This fills `backend/wheelhouse/` with `.whl` files for every dependency (including transitive ones
like `pydantic-core`, `starlette`, `anyio`, `uvloop`, etc.).

---

## Step 2 — Move `wheelhouse/` to the restricted machine

Copy the whole `backend/wheelhouse/` folder over (USB, network share, git — it's already gitignored
by default; commit it deliberately if you want it in the repo). Keep it at `backend/wheelhouse/`.

---

## Step 3 — Install from the local wheelhouse (no network)

On the restricted (Windows) machine, from `backend/`:

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1

# Install deps from local wheels only — never touches the network:
python -m pip install --no-index --find-links=wheelhouse -r requirements.txt
```

You do **not** need to `pip install -e .` — running `python -m pytest` from `backend/` (below) puts
this folder on `sys.path`, so `import app` resolves without installing the project. (Skipping it also
avoids re-resolving the `pyproject.toml` `uvicorn[standard]` deps, which aren't in the Windows
wheelhouse — see Troubleshooting.)

---

## Step 4 — Run

```powershell
python -m pytest -q            # tests (mock mode, fully offline)
uvicorn app.main:app --reload  # http://localhost:8000/docs
```

---

## Troubleshooting

**`Cannot install uvicorn[standard]==... because these package versions have conflicting
dependencies`** during Step 1 (cross-download).

Cause: `uvicorn[standard]` depends on **`uvloop`**, which is **Unix-only and has no Windows wheel**.
When cross-downloading for `win_amd64`, pip evaluates dependency markers against the Linux machine it
runs on (not the Windows target), so it demands `uvloop`, can't find a Windows wheel, and fails.

Fix: this is already handled — `requirements.txt` uses **plain `uvicorn`** plus `websockets` and
`watchfiles` (all Windows-friendly) instead of `uvicorn[standard]`. Make sure you pulled the latest
`requirements.txt` and re-run the Step 1 download. (The Linux Cloud Run image still uses
`uvicorn[standard]` via `pyproject.toml`, where `uvloop` works.)

---

## Making it permanent (optional)

To make pip always prefer your org's internal index instead of doing this by hand, set it once:

```powershell
# If your org has an internal mirror, point pip at it globally:
python -m pip config set global.index-url https://<your-internal-index>/simple
python -m pip config set global.trusted-host <your-internal-host>
```

Ask your platform/IT team for the internal PyPI index URL — that's the cleanest long-term fix and
removes the manual wheelhouse step.
