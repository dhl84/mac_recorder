#!/usr/bin/env python3
"""Practice mode: ask one interview question, record the answer, evaluate it.

The app runs this script. This script records nothing and marks nothing itself.
The questions and the marking come from a practice pack: a folder that you keep
outside this repository, with a file pack.py that holds three functions:

    stages() -> [{"id": "...", "name": "..."}]
    question(stage, history) -> {"id": "...", "text": "...", "seconds": 120}
    evaluate(stage, question, answer, ask) -> {"score": 7, "markdown": "..."}

history is the list of earlier attempts, oldest first (the rows of history.jsonl).
answer is {"text": ..., "seconds": ..., "words": ...}. ask(system, user) sends one
prompt to the engine that you chose and returns the reply text. "seconds" in a
question is the target length of the answer, and the score can be None.
`practice-pack-template/` in this repository is a pack to copy and change.

    practice.py stages
    practice.py question STAGE
    practice.py evaluate FOLDER [--seconds N]
    practice.py selftest

Each command prints one JSON object. A failure gives {"error": "..."}.

PRACTICE_PACK is the pack folder (default ~/practice-pack). PRACTICE_HOME holds
one folder for each attempt and history.jsonl (default ~/Documents/InterviewPractice).
PRACTICE_ENGINE picks the model:

    claude  the claude CLI and your Claude subscription (the default)
    codex   the codex CLI and your ChatGPT subscription
    ollama  a local model at OLLAMA_HOST

PRACTICE_MODEL overrides the model of the engine.
"""
import argparse
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

ENGINE = os.environ.get("PRACTICE_ENGINE", "claude")
MODEL = os.environ.get("PRACTICE_MODEL") or {
    "claude": "claude-fable-5-1", "ollama": "gemma4:26b-a4b-it-qat"}.get(ENGINE, "")
FALLBACK = os.environ.get("PRACTICE_FALLBACK", "claude-opus-5-5")
OLLAMA = os.environ.get("OLLAMA_HOST", "http://localhost:11434").rstrip("/") + "/api/chat"
PACK = Path(os.environ.get("PRACTICE_PACK", "~/practice-pack")).expanduser()
HOME = Path(os.environ.get("PRACTICE_HOME", "~/Documents/InterviewPractice")).expanduser()
WHISPER_MODEL = os.environ.get("INTERVIEW_WHISPER_MODEL") or str(Path.home() / (
    "Library/Application Support/ru.starmel.OpenSuperWhisper/whisper-models/ggml-large-v3-turbo.bin"))
VAD_MODEL = os.environ.get("INTERVIEW_VAD_MODEL") or str(
    Path.home() / ".cache/whisper-vad/ggml-silero-v5.1.2.bin")
# A Finder launch gives a short PATH, so look in the usual places.
PATH = os.pathsep.join([os.environ.get("PATH", ""), str(Path.home() / ".local/bin"),
                        "/opt/homebrew/bin", "/usr/local/bin"])


def load_pack(folder=None):
    folder = Path(folder or PACK)
    file = folder / "pack.py"
    if not file.exists():
        raise RuntimeError(f"No practice pack at {folder}. Copy practice-pack-template "
                           "from the repository there, or pick your pack folder in the window.")
    spec = importlib.util.spec_from_file_location("practice_pack", file)
    pack = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(pack)
    return pack


def history():
    file = HOME / "history.jsonl"
    if not file.exists():
        return []
    return [json.loads(line) for line in file.read_text().splitlines() if line.strip()]


# --- the engines -------------------------------------------------------------

def ask(system, user):
    """One prompt to the chosen engine. Returns the reply text."""
    if ENGINE == "ollama":
        body = json.dumps({"model": MODEL, "stream": False, "think": False,
                           "options": {"num_ctx": 32768, "temperature": 0.2},
                           "messages": [{"role": "system", "content": system},
                                        {"role": "user", "content": user}]}).encode()
        request = urllib.request.Request(OLLAMA, body, {"Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=600) as response:
            return json.load(response)["message"]["content"]
    if ENGINE == "codex":
        return ask_codex(system, user)
    return ask_claude(system, user)


def ask_claude(system, user):
    claude = shutil.which("claude", path=PATH)
    if not claude:
        raise RuntimeError("No claude CLI on the PATH. Install Claude Code, or pick another engine.")

    # --safe-mode skips the hooks, plugins and CLAUDE.md, so each call is plain.
    def call(model):
        return subprocess.run([claude, "-p", "--safe-mode", "--strict-mcp-config", "--tools", "",
                               "--no-session-persistence", "--model", model,
                               "--fallback-model", FALLBACK, "--system-prompt", system],
                              input=user, capture_output=True, text=True, timeout=600,
                              cwd=tempfile.gettempdir())
    run = call(MODEL)
    # --fallback-model covers an overloaded model only, not a spent usage limit.
    if run.returncode and MODEL != FALLBACK and "limit" in (run.stderr + run.stdout).lower():
        run = call(FALLBACK)
    if run.returncode:
        raise RuntimeError(f"claude failed: {(run.stderr or run.stdout)[-300:]}")
    return run.stdout


def ask_codex(system, user):
    codex = shutil.which("codex", path=PATH)
    if not codex:
        raise RuntimeError("No codex CLI on the PATH. Install Codex, or pick another engine.")
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "reply.md"
        # A read-only sandbox in an empty folder: the agent can read nothing of yours.
        args = [codex, "exec", "--skip-git-repo-check", "--ephemeral", "-s", "read-only",
                "--color", "never", "-C", tmp, "-o", str(out)]
        if MODEL:
            args += ["-m", MODEL]
        run = subprocess.run(args + ["-"], input=f"{system}\n\n{user}", capture_output=True,
                             text=True, timeout=600, cwd=tmp)
        if run.returncode or not out.exists():
            raise RuntimeError(f"codex failed: {(run.stderr or run.stdout)[-300:]}")
        return out.read_text()


# --- the answer --------------------------------------------------------------

def transcribe(wav):
    binary = shutil.which("whisper-cli", path=PATH)
    if not binary:
        raise RuntimeError("No whisper-cli on the PATH. Install whisper-cpp.")
    args = [binary, "-m", WHISPER_MODEL, "-f", str(wav), "-l", "en", "-nt", "-np"]
    if Path(VAD_MODEL).exists():
        args += ["--vad", "-vm", VAD_MODEL]
    run = subprocess.run(args, capture_output=True, text=True, timeout=600)
    if run.returncode:
        raise RuntimeError(f"whisper-cli failed: {run.stderr[-300:]}")
    return " ".join(line.strip() for line in run.stdout.splitlines() if line.strip())


def slug(text):
    return "-".join(re.findall(r"[a-z0-9]+", text.lower()))[:60]


def new_question(stage):
    pack = load_pack()
    q = pack.question(stage, history())
    # A skipped question has no answer.wav. Remove its folder, so each folder is an attempt.
    for old in HOME.glob("*/question.json"):
        if not (old.parent / "answer.wav").exists():
            shutil.rmtree(old.parent)
    folder = HOME / f"{time.strftime('%Y%m%d-%H%M%S')}-{slug(stage)}"
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "question.json").write_text(json.dumps({"stage": stage, **q}, indent=2))
    return {**q, "folder": str(folder)}


def evaluate(folder, seconds=None):
    """Transcribes answer.wav once, asks the pack for the marks, writes evaluation.md
    and adds one row to history.jsonl. A second run keeps the transcript."""
    folder = Path(folder)
    q = json.loads((folder / "question.json").read_text())
    text_file = folder / "answer.md"
    if not text_file.exists():
        text_file.write_text(transcribe(folder / "answer.wav") + "\n")
    text = text_file.read_text().strip()
    if seconds is None:  # 16 kHz mono 16-bit, so 32,000 bytes a second
        wav = folder / "answer.wav"
        seconds = wav.stat().st_size / 32_000 if wav.exists() else 0
    answer = {"text": text, "seconds": round(seconds), "words": len(text.split())}
    result = load_pack().evaluate(q["stage"], q, answer, ask)
    score = result.get("score")
    head = (f"# {q['text']}\n\n"
            f"Answer: {answer['seconds']} seconds, {answer['words']} words"
            + (f" (target {q['seconds']} seconds)" if q.get("seconds") else "")
            + f". Engine: {ENGINE} {MODEL}".rstrip() + ".\n\n")
    (folder / "evaluation.md").write_text(head + result["markdown"].strip() + "\n")
    row = {"at": time.strftime("%Y-%m-%dT%H:%M:%S"), "stage": q["stage"], "question": q["id"],
           "text": q["text"], "score": score, "seconds": answer["seconds"],
           "words": answer["words"], "engine": ENGINE, "folder": folder.name}
    with open(HOME / "history.jsonl", "a") as f:
        f.write(json.dumps(row) + "\n")
    return {"score": score, "file": str(folder / "evaluation.md")}


# --- the self-test -----------------------------------------------------------

def selftest():
    global PACK, HOME, ENGINE, ask
    tmp = Path(tempfile.mkdtemp())
    saved = PACK, HOME, ENGINE, ask
    try:
        PACK, HOME = tmp / "pack", tmp / "home"
        PACK.mkdir()
        (PACK / "pack.py").write_text(
            "def stages():\n    return [{'id': 'screen', 'name': 'Screen'}]\n"
            "def question(stage, history):\n"
            "    asked = {h['question'] for h in history}\n"
            "    q = next(i for i in ('Q1', 'Q2') if i not in asked)\n"
            "    return {'id': q, 'text': 'Why this role?', 'seconds': 90}\n"
            "def evaluate(stage, question, answer, ask):\n"
            "    return {'score': 6, 'markdown': ask('rules', answer['text'])}\n")
        assert load_pack().stages() == [{"id": "screen", "name": "Screen"}]

        asked = []
        ask = lambda system, user: asked.append((system, user)) or "Lead with the result."
        q = new_question("screen")
        folder = Path(q["folder"])
        assert q["id"] == "Q1" and json.loads((folder / "question.json").read_text())["stage"] == "screen"
        (folder / "answer.wav").write_bytes(b"")
        (folder / "answer.md").write_text("I built the forecast at Acme.\n")
        out = evaluate(folder, seconds=42)
        assert out["score"] == 6 and asked == [("rules", "I built the forecast at Acme.")]
        body = (folder / "evaluation.md").read_text()
        assert "42 seconds, 6 words (target 90 seconds)" in body and "Lead with the result." in body
        assert history()[0]["question"] == "Q1"
        skipped = Path(new_question("screen")["folder"])
        later = new_question("screen")
        assert later["id"] == "Q2" and folder.exists()
        assert not skipped.exists() or skipped == Path(later["folder"])

        try:
            load_pack(tmp / "none")
            raise AssertionError("a missing pack must fail")
        except RuntimeError as e:
            assert "No practice pack" in str(e)

        # codex gets one prompt on stdin and gives the reply in the -o file.
        real_run, real_which = subprocess.run, shutil.which
        def fake_run(args, **kw):
            Path(args[args.index("-o") + 1]).write_text("ok")
            assert args[-1] == "-" and kw["input"] == "s\n\nu"
            return subprocess.CompletedProcess(args, 0, "", "")
        subprocess.run, shutil.which = fake_run, lambda *a, **k: "/bin/codex"
        try:
            assert ask_codex("s", "u") == "ok"
        finally:
            subprocess.run, shutil.which = real_run, real_which
        print("practice self-test: ok")
    finally:
        PACK, HOME, ENGINE, ask = saved
        shutil.rmtree(tmp)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("action", choices=["stages", "question", "evaluate", "selftest"])
    parser.add_argument("target", nargs="?", help="the stage id, or the attempt folder")
    parser.add_argument("--seconds", type=float)
    args = parser.parse_args()
    if args.action == "selftest":
        return selftest()
    try:
        if args.action == "stages":
            out = {"stages": load_pack().stages()}
        elif not args.target:
            out = {"error": f"{args.action} needs a {'stage' if args.action == 'question' else 'folder'}"}
        elif args.action == "question":
            out = new_question(args.target)
        else:
            out = evaluate(args.target, args.seconds)
    except Exception as e:  # the app shows the reason in the window
        out = {"error": f"{type(e).__name__}: {e}"[:500]}
    print(json.dumps(out))


if __name__ == "__main__":
    main()
