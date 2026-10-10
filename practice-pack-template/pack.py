"""A practice pack to copy and change.

The practice mode of Interview Recorder calls the three functions below. Keep your
own pack outside the public repository, because the questions, the marking rules
and your examples are yours. Copy this folder, then pick the copy in the Practice
window (Change).

Make the pack yours: write the questions for the stages that you face, and put
in RULES what a good answer holds for you, with the facts and numbers that
your answers must use. Better rules give better marks. See the README.
"""
import random
import re
from pathlib import Path

HERE = Path(__file__).parent


def _bank():
    """Each "## " heading in questions.md starts a stage. Each "- " line is a question."""
    stages, current = {}, None
    for line in (HERE / "questions.md").read_text().splitlines():
        if line.startswith("## "):
            current = line[3:].strip()
            stages[current] = []
        elif line.startswith("- ") and current:
            stages[current].append(line[2:].strip())
    return stages


def stages():
    return [{"id": name, "name": name} for name in _bank()]


def question(stage, history):
    """A question not yet asked in this stage. After all of them, any question."""
    bank = _bank()[stage]
    asked = {h["question"] for h in history if h["stage"] == stage}
    fresh = [i for i in range(len(bank)) if f"Q{i + 1}" not in asked] or list(range(len(bank)))
    i = random.choice(fresh)
    return {"id": f"Q{i + 1}", "text": bank[i], "seconds": 120}


RULES = """You coach a job candidate. Mark one spoken answer to one interview question.
The answer comes from speech recognition, so ignore single odd words.
Reply in Markdown, in this form:

Score: N/10

## What worked

## Fix next time
At most three points, the most important first.

## A stronger answer
About 150 words, in a spoken style. Use only the facts that the answer gives."""


def evaluate(stage, question, answer, ask):
    reply = ask(RULES, f"Stage: {stage}\nQuestion: {question['text']}\n"
                       f"Answer ({answer['seconds']} seconds, {answer['words']} words):\n"
                       f"{answer['text']}")
    match = re.search(r"Score:\s*(\d+)", reply)
    return {"score": int(match.group(1)) if match else None, "markdown": reply}
