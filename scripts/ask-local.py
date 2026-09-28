#!/usr/bin/env python3
"""Ask the lab's own model to produce a JSON file, and refuse to accept it
until the real gate says yes.

This replaces `claude -p` for the two daily sessions — the dispatch and the
suggested questions. Both were measured against their production gates on
2026-09-08 before this existed: dispatch 20/20 first shot, openers 15/15 and
14/15 with one retry, and zero hostile candidates published out of 35.

WHY THOSE TWO AND NOT THE OTHERS. They are the only sessions whose task is
bounded, whose output is short, and whose result is judged by a deterministic
program. Sessions A and C cross-reference four repositories against 853 lines
of prose; B decides what a drawing should show. Those are judgment on
contradictory sources, which is what a hosted model is for.

WHAT THIS IS NOT. It is not an agent. There is no tool loop, no file system
access, no turns budget — one call, the gate, and at most one correction. The
prompts already end with "run the gate yourself and fix what it refuses", and
that is exactly the shape reproduced here. Anything needing more than one
correction is a session that should not be local.

THE GATE IS THE CONTRACT. It is never relaxed to fit the model: if the local
one starts drifting, this exits non-zero and the job goes red rather than
publishing something wrong. That property is the whole reason moving these
two is safe.

Usage:
  ask-local.py --prompt <prompt.md> --out <result.json> \\
               [--attach name=<file.json>]... \\
               -- <check-cmd> [args...]     # $OUT is substituted

The check command is run with the written file; its stderr becomes the
correction message on the retry.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

# The one model resident on gpu-01. Both callers of that server — this job and the
# site's Worker — must agree on the name AND on num_ctx: Ollama starts a new
# runner when the context size changes, which costs a ~30 s reload every time
# the two disagree. 16384 is what the Worker sends.
# qwen38-27b (Qwen3.8-27B dense) since 2026-09-26, for every caller of gpu-01.
MODEL = os.environ.get("OLLAMA_MODEL", "qwen38-27b")
OLLAMA = os.environ.get("OLLAMA_URL", "http://192.0.2.129:11434/api/chat")
NUM_CTX = 16_384
NUM_PREDICT = 600
# Since 2026-09-13 the default is a HOSTED model through an OpenAI-compatible
# endpoint (Alibaba Cloud Model Studio, qwen3.8-flash): the local 35B picked,
# as a suggested question, the very false-premise example its prompt told it
# to reject. ASK_BACKEND=ollama brings the local path back. The key comes from
# the environment of this one process (the driver reads it from KeePass).
BACKEND = os.environ.get("ASK_BACKEND", "openai")
OPENAI_BASE = os.environ.get("ASK_OPENAI_BASE", "https://dashscope-intl.aliyuncs.com/compatible-mode/v1")
OPENAI_MODEL = os.environ.get("ASK_OPENAI_MODEL", "qwen3.8-flash")
# Generous: this runs at 04:30 sharing a model that may need loading first, and
# a job that fails on a slow morning is worse than one that waits.
TIMEOUT = 300


def ask(messages):
    if BACKEND == "openai":
        body = json.dumps({"model": OPENAI_MODEL, "messages": messages, "temperature": 0.3,
                           "max_tokens": NUM_PREDICT, "enable_thinking": False}).encode()
        req = urllib.request.Request(f"{OPENAI_BASE}/chat/completions", data=body,
                                     headers={"content-type": "application/json",
                                              "authorization": "Bearer " + os.environ.get("ASK_API_KEY", "")})
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return json.load(r)["choices"][0]["message"]["content"].strip()
    body = json.dumps({
        "model": MODEL, "stream": False, "think": False, "messages": messages,
        "keep_alive": -1,
        "options": {"num_predict": NUM_PREDICT, "num_ctx": NUM_CTX},
    }).encode()
    req = urllib.request.Request(OLLAMA, data=body,
                                 headers={"content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return json.load(r)["message"]["content"].strip()


def extract(reply):
    """A session writes a file; a bare model returns prose around JSON.

    Greedy on purpose — the outermost braces — so a JSON body containing its
    own braces survives. Returns None rather than raising: a reply that is not
    JSON is a refusal like any other, and the retry says so.
    """
    m = re.search(r"\{.*\}", reply, re.S)
    if not m:
        return None
    try:
        return json.loads(m.group(0))
    except json.JSONDecodeError:
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--prompt", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--attach", action="append", default=[],
                    help="name=path — inlined into the request as a fenced block")
    ap.add_argument("check", nargs=argparse.REMAINDER)
    a = ap.parse_args()
    check = [x for x in a.check if x != "--"]
    if not check:
        print("ask-local: no check command given", file=sys.stderr)
        return 2

    task = open(a.prompt, encoding="utf-8").read()
    for spec in a.attach:
        name, path = spec.split("=", 1)
        task += f"\n\nVoici `{name}` :\n\n```json\n{open(path, encoding='utf-8').read()}\n```"
    task += ("\n\nRéponds UNIQUEMENT avec le contenu du fichier JSON demandé, "
             "sans texte autour.")

    messages = [{"role": "user", "content": task}]
    # FOUR CORRECTIONS, NOT TWO (2026-09-16). The ceiling used to be three
    # attempts, chosen when check-openers grew a per-language floor: the first
    # correction tends to overshoot (five French where four is the cap) and
    # the second lands.
    #
    # Three turned out to be exactly the top of the distribution, not past it.
    # Five runs of the suggested-questions session on one day needed 1, 2, 3, 3
    # and then more than 3 — so the job went red, and the panel shipped eight
    # questions gpu-01 wrote and none a visitor asked. The 07:05 run had landed on
    # its very last attempt with the same two refusals.
    #
    # Every refusal that day was a SHAPE error the gate catches — no usable
    # JSON, a counter-example the prompt names, five French where four is the
    # cap — never a wrong claim. Those are what another correction fixes.
    #
    # The cost argument still holds and is why this is cheap rather than
    # reckless: the model is local, and a refused attempt is two or three
    # seconds. Raising the ceiling buys attempts, never a relaxed gate — the
    # gate is unchanged, and a run that exhausts five still fails loudly.
    attempts = int(os.environ.get("ASK_ATTEMPTS", "5"))
    for attempt in range(1, attempts + 1):
        t0 = time.time()
        try:
            reply = ask(messages)
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            print(f"ask-local: model unreachable: {e}", file=sys.stderr)
            return 1
        obj = extract(reply)
        took = time.time() - t0

        if obj is None:
            why = "ta réponse ne contenait pas de JSON exploitable"
        else:
            with open(a.out, "w", encoding="utf-8") as fh:
                json.dump(obj, fh, ensure_ascii=False, indent=2)
                fh.write("\n")
            r = subprocess.run([x.replace("$OUT", a.out) for x in check],
                               capture_output=True, text=True)
            if r.returncode == 0:
                print(f"ask-local: ok on attempt {attempt} ({took:.1f}s, {OPENAI_MODEL if BACKEND == 'openai' else MODEL}) — {r.stdout.strip()}")
                return 0
            why = r.stderr.strip() or r.stdout.strip()

        print(f"ask-local: attempt {attempt} refused — {why[:200]}", file=sys.stderr)
        if attempt == attempts:
            break
        messages += [
            {"role": "assistant", "content": reply},
            {"role": "user", "content": f"La garde refuse : {why}\n"
                                        "Corrige et renvoie uniquement le JSON."},
        ]

    # The file on disk is the refused attempt; the caller must not publish it.
    try:
        os.unlink(a.out)
    except OSError:
        pass
    return 1


if __name__ == "__main__":
    sys.exit(main())
