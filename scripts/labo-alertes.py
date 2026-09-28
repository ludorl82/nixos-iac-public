#!/usr/bin/env python3
"""labo-alertes — les alertes du labo en une commande, pour un humain ou un agent.

Les alertes du labo, ce sont les moniteurs Uptime Kuma (ils poussent vers
ntfy). Imprime :
  * les moniteurs ACTIFS qui ne sont pas « up » en ce moment (en panne, en
    attente, en maintenance), avec leur message ;
  * les changements d'état des dernières heures (défaut 24), le plus récent
    en premier.
Rien à signaler : une seule ligne le dit. Lecture seule.

    labo-alertes [heures]

Tourne dans le conteneur console : identifiants lus par kp-get sur le jumphost
(pi-02), jamais dans un fichier — le même chemin que kuma-silence.py.
~8 s, dont ~5 s pour les deux kp-get, faits en parallèle.
"""
import concurrent.futures as cf
import datetime as dt
import subprocess
import sys
import time

from uptime_kuma_api import UptimeKumaApi

STATUS = {0: "EN PANNE", 1: "ok", 2: "en attente", 3: "maintenance"}


def kp(entry):
    return subprocess.run(["ssh", "-4", "-n", "-o", "BatchMode=yes", "pi-02.lab.example", f'kp-get "{entry}"'],
                          check=True, capture_output=True, text=True, timeout=30).stdout.strip()


def when(s):
    t = dt.datetime.strptime(s.split(".")[0], "%Y-%m-%d %H:%M:%S").replace(tzinfo=dt.timezone.utc)
    return t, t.astimezone().strftime("%d %b %H:%M")


def main():
    hours = float(sys.argv[1]) if len(sys.argv) > 1 else 24
    with cf.ThreadPoolExecutor(2) as ex:
        cred, pw = ex.map(kp, ["Cloudflare Kuma Service Token", "Kuma"])
    cid, csec = cred.split(":", 1)
    api = None
    for attempt in range(3):
        try:
            api = UptimeKumaApi("https://kuma.pub.example.com", timeout=60,
                                headers={"CF-Access-Client-Id": cid, "CF-Access-Client-Secret": csec})
            api.login("admin", pw)
            break
        except Exception as e:  # noqa: BLE001 — the socket is chatty at login
            print(f"(connexion à Kuma, essai {attempt + 1} : {e!r})", file=sys.stderr)
            api = None
            time.sleep(3)
    if api is None:
        sys.exit("labo-alertes : impossible de joindre Uptime Kuma")
    mons = {m["id"]: m for m in api.get_monitors()}
    # Kuma 2 no longer pushes the "important heartbeat" list at login (the
    # library's get_important_heartbeats() times out), so status changes are
    # read off the recent beats Kuma does send: a change is a beat whose
    # status differs from the one before it. That window is the last ~100
    # beats per monitor, so « depuis » can be « au moins depuis ».
    beats = api.get_heartbeats()
    api.disconnect()

    since = dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=hours)
    changes, now_bad = [], []
    for mid, hb in beats.items():
        m = mons.get(int(mid))
        if not m or not m.get("active") or not hb:
            continue
        # Some monitors come back as a list of beat LISTS (Kuma 2 batches
        # them); flatten before ordering.
        flat = []
        for b in hb:
            flat.extend(b if isinstance(b, list) else [b])
        hb = sorted((b for b in flat if isinstance(b, dict) and "time" in b), key=lambda b: b["time"])
        if not hb:
            continue
        for prev, b in zip(hb, hb[1:]):
            if int(b["status"]) != int(prev["status"]):
                t, s = when(b["time"])
                if t >= since:
                    changes.append((t, s, m["name"], STATUS.get(int(b["status"]), b["status"]),
                                    (b.get("msg") or "").strip()[:100]))
        st = int(hb[-1]["status"])
        if st != 1:
            start = len(hb) - 1
            while start > 0 and int(hb[start - 1]["status"]) == st:
                start -= 1
            depuis = ("au moins " if start == 0 else "") + when(hb[start]["time"])[1]
            now_bad.append((m["name"], STATUS.get(st, st), (hb[-1].get("msg") or "").strip()[:120], depuis))

    active = sum(1 for m in mons.values() if m.get("active"))
    if not now_bad:
        print(f"Aucune alerte en cours : les {active} moniteurs actifs sont « up ».")
    else:
        print(f"{len(now_bad)} alerte(s) en cours sur {active} moniteurs actifs :")
        for name, st, msg, t in sorted(now_bad):
            print(f"  - {name} : {st} depuis {t}" + (f" — {msg}" if msg else ""))
    changes.sort(reverse=True)
    print(f"\nChangements d'état des dernières {hours:g} h : {len(changes) or 'aucun'}")
    for _, s, name, st, msg in changes[:25]:
        print(f"  {s}  {name} -> {st}" + (f" — {msg}" if msg else ""))


if __name__ == "__main__":
    main()
