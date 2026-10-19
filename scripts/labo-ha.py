#!/usr/bin/env python3
"""labo-ha — la MAISON dans Home Assistant pour l'observateur, pas le labo.

    labo-ha pieces                              les pièces et ce qu'on y pilote
    labo-ha etat [mots…]                        l'état de ce qui est exposé à Assist
    labo-ha action <domaine.service> <cible…> [clé=valeur…]
        cible = light.bureau… ou piece:<nom>    (piece: = ce qui est PILOTABLE dans la pièce)
    labo-ha action script.meteo [clé=valeur…]   scripts permis, réponse affichée

Ce qui est permis (décision de Ludo, 2026-09-28 : « la maison, pas le labo ») :
  - lire ce qui est exposé à Assist (la liste que Ludo tient dans HA) ;
  - agir sur ce qui est exposé ET d'un domaine de la maison (lumières, médias,
    climat, ventilateurs, stores, scènes…) ;
  - les interrupteurs et les scripts SEULEMENT par nom (SWITCHES, SCRIPTS) : la
    plupart des interrupteurs exposés alimentent des machines du labo (stella,
    le NAS, coquille — l'hôte de l'observateur lui-même). Un nouvel interrupteur
    exposé reste donc refusé tant qu'on ne l'ajoute pas ici.
Une commande dont UNE cible est refusée est refusée en entier : rien ne part.
Code de sortie : 0 fait, 64 refusé ici, 1 erreur de Home Assistant.

Jeton : utilisateur HA « Observateur », NON admin (pas d'automatisations,
d'intégrations ni d'utilisateurs) : $LABO_HA_TOKEN si le serveur de
l'observateur l'a chargé, sinon lu dans KeePass — aucun fichier. Tests : LABO_HA_FAKE=<état.json> remplace Home Assistant.
"""
import json
import os
import shlex
import socket
import ssl
import subprocess
import sys
import time
import unicodedata

IP = os.environ.get("LABO_HA_IP", "192.0.2.34")
NAME = os.environ.get("LABO_HA_NAME", "automatron.family.example")   # le SAN du certificat Origin
CA = os.environ.get("LABO_HA_CA", os.path.expanduser("~/.local/share/labo-ha/cloudflare-origin-roots.crt"))
TOKEN_CMD = os.environ.get("LABO_HA_TOKEN_CMD",
                           "ssh -4 -n -o BatchMode=yes worker2.lab.example 'kp-get \"Home Assistant Observateur Token\"'")
FAKE = os.environ.get("LABO_HA_FAKE")

PILOTABLE = {
    "light": {"turn_on", "turn_off", "toggle"},
    "media_player": {"turn_on", "turn_off", "toggle", "media_play", "media_pause", "media_play_pause",
                     "media_stop", "media_next_track", "media_previous_track", "volume_set", "volume_up",
                     "volume_down", "volume_mute", "select_source", "play_media", "shuffle_set", "repeat_set"},
    "climate": {"turn_on", "turn_off", "set_temperature", "set_hvac_mode", "set_preset_mode", "set_fan_mode"},
    "fan": {"turn_on", "turn_off", "toggle", "set_percentage", "oscillate", "set_preset_mode", "set_direction"},
    "cover": {"open_cover", "close_cover", "stop_cover", "set_cover_position", "toggle"},
    "scene": {"turn_on"},
    "humidifier": {"turn_on", "turn_off", "set_humidity", "set_mode"},
    "vacuum": {"start", "pause", "stop", "return_to_base", "locate"},
    "water_heater": {"turn_on", "turn_off", "set_temperature", "set_operation_mode"},
    "switch": {"turn_on", "turn_off", "toggle"},
}
SWITCHES = {"switch.purificateur"}
SCRIPTS = {"script.meteo", "script.horaires_cinema", "script.recherche_web"}
SHOWN_ATTRS = ("brightness", "color_temp_kelvin", "temperature", "current_temperature", "hvac_action",
               "media_title", "media_artist", "volume_level", "source", "percentage", "current_position",
               "unit_of_measurement")


def refuse(msg):
    print(f"labo-ha : refusé — {msg}", file=sys.stderr)
    sys.exit(64)


def fold(s):
    return "".join(c for c in unicodedata.normalize("NFD", str(s).lower()) if unicodedata.category(c) != "Mn")


class Real:
    def __init__(self):
        # The observer's server reads the token once at start (LABO_HA_TOKEN);
        # anyone else (Claude, a human) goes through KeePass: 2.5 s per call.
        token = os.environ.get("LABO_HA_TOKEN", "").strip()
        if not token:
            r = subprocess.run(TOKEN_CMD, shell=True, capture_output=True, text=True, timeout=30)
            token = r.stdout.strip() if not r.returncode else ""
        if not token:
            print("labo-ha : jeton introuvable (KeePass « Home Assistant Observateur Token »)", file=sys.stderr)
            sys.exit(1)
        import websocket
        ctx = ssl.create_default_context(cafile=CA)
        sock = ctx.wrap_socket(socket.create_connection((IP, 443), timeout=20), server_hostname=NAME)
        self.ws = websocket.create_connection(f"wss://{NAME}/api/websocket", socket=sock, timeout=30)
        self.ws.recv()
        self.ws.send(json.dumps({"type": "auth", "access_token": token}))
        if json.loads(self.ws.recv()).get("type") != "auth_ok":
            print("labo-ha : Home Assistant a refusé le jeton", file=sys.stderr)
            sys.exit(1)
        self.n = 0

    def call(self, typ, **kw):
        self.n += 1
        self.ws.send(json.dumps({"id": self.n, "type": typ, **kw}))
        while True:
            m = json.loads(self.ws.recv())
            if m.get("id") == self.n:
                if not m.get("success"):
                    print(f"labo-ha : Home Assistant : {(m.get('error') or {}).get('message')}", file=sys.stderr)
                    sys.exit(1)
                return m.get("result")

    def load(self):
        return {"areas": self.call("config/area_registry/list"), "devices": self.call("config/device_registry/list"),
                "entities": self.call("config/entity_registry/list"), "states": self.call("get_states")}

    def service(self, domain, service, entities, data, response):
        kw = {"domain": domain, "service": service, "service_data": data}
        if entities:
            kw["target"] = {"entity_id": entities}
        if response:
            kw["return_response"] = True
        return self.call("call_service", **kw)


class Fake:   # tests: the whole house in one JSON file, every call logged beside it
    def load(self):
        with open(FAKE) as f:
            return json.load(f)

    def service(self, domain, service, entities, data, response):
        with open(FAKE + ".calls", "a") as f:
            f.write(json.dumps({"domain": domain, "service": service, "entities": entities, "data": data}) + "\n")
        h = self.load()
        for s in h["states"]:
            if s["entity_id"] in entities and service in ("turn_on", "turn_off"):
                s["state"] = "on" if service == "turn_on" else "off"
        with open(FAKE, "w") as f:
            json.dump(h, f)
        return {"response": {"fake": True}} if response else None


class House:
    def __init__(self, backend):
        self.b = backend
        h = backend.load()
        self.area_name = {a["area_id"]: a["name"] for a in h["areas"]}
        dev_area = {d["id"]: d.get("area_id") for d in h["devices"]}
        self.reg = {e["entity_id"]: e for e in h["entities"]}
        self.state = {s["entity_id"]: s for s in h["states"]}
        self.area = {eid: (e.get("area_id") or dev_area.get(e.get("device_id"))) for eid, e in self.reg.items()}

    def exposed(self, eid):
        e = self.reg.get(eid)
        return bool(e and not e.get("disabled_by")
                    and ((e.get("options") or {}).get("conversation") or {}).get("should_expose"))

    def why_not(self, eid, domain):
        """None if `eid` may be driven by a `domain` service, else the reason."""
        if eid not in self.reg and eid not in self.state:
            return "entité inconnue"
        if not self.exposed(eid):
            return "pas exposée à Assist"
        d = eid.split(".", 1)[0]
        if d != domain:
            return f"un service {domain} ne pilote pas un {d}"
        if d not in PILOTABLE:
            return f"domaine {d} hors de la maison"
        if d == "switch" and eid not in SWITCHES:
            return "interrupteur non listé (ceux du labo alimentent des machines)"
        return None

    def find_area(self, word):
        w = fold(word)
        hits = [a for a, n in self.area_name.items() if fold(a) == w or fold(n) == w]
        if not hits:
            refuse(f"pièce inconnue : {word} (voir labo-ha pieces)")
        return hits[0]

    def name(self, eid):
        return (self.state.get(eid, {}).get("attributes") or {}).get("friendly_name") or eid

    def line(self, eid):
        s = self.state.get(eid)
        if not s:
            return f"  {eid} : (pas d'état)"
        a = s.get("attributes") or {}
        extra = ", ".join(f"{k}={a[k]}" for k in SHOWN_ATTRS if a.get(k) not in (None, ""))
        mark = " [pilotable]" if self.why_not(eid, eid.split(".", 1)[0]) is None else ""
        return f"  {eid} ({self.name(eid)}) : {s['state']}{' — ' + extra if extra else ''}{mark}"


def parse_data(pairs):
    data = {}
    for p in pairs:
        k, _, v = p.partition("=")
        try:
            data[k] = json.loads(v)
        except ValueError:
            data[k] = v
    return data


def main(argv):
    if not argv or argv[0] not in ("pieces", "etat", "action"):
        print(__doc__.split("\n\n")[1] if "\n\n" in __doc__ else __doc__, file=sys.stderr)
        sys.exit(64)
    cmd, args = argv[0], argv[1:]
    house = House(Fake() if FAKE else Real())

    if cmd == "pieces":
        by_area = {}
        for eid in house.reg:
            if house.exposed(eid) and house.why_not(eid, eid.split(".", 1)[0]) is None:
                by_area.setdefault(house.area.get(eid), []).append(eid)
        for a in sorted(by_area, key=lambda x: house.area_name.get(x, "~")):
            print(f"{house.area_name.get(a, '(sans pièce)')} [piece:{a}]" if a else "(sans pièce)")
            for eid in sorted(by_area[a]):
                print(house.line(eid))
        return 0

    if cmd == "etat":
        words = [fold(w) for w in args]
        shown = 0
        for eid in sorted(house.reg):
            if not house.exposed(eid):
                continue
            hay = fold(f"{eid} {house.name(eid)} {house.area_name.get(house.area.get(eid), '')}")
            if all(w in hay for w in words):
                print(house.line(eid))
                shown += 1
        if not shown:
            print("rien d'exposé à Assist ne correspond")
        return 0

    # action
    if not args or "." not in args[0]:
        refuse("usage : labo-ha action <domaine.service> <cible…> [clé=valeur…]")
    domain, service = args[0].split(".", 1)
    targets = [a for a in args[1:] if "=" not in a]
    data = parse_data([a for a in args[1:] if "=" in a])
    if "entity_id" in data or "area_id" in data or "device_id" in data:
        refuse("les cibles se donnent en arguments, pas en clé=valeur")

    if domain == "script" and service not in ("turn_on", "turn_off", "toggle"):
        if f"script.{service}" not in SCRIPTS:
            refuse(f"script.{service} n'est pas dans la liste permise ({', '.join(sorted(SCRIPTS))})")
        if targets:
            refuse("un script s'appelle sans cible")
        res = house.b.service("script", service, [], data, True)
        print(json.dumps((res or {}).get("response", res), ensure_ascii=False, indent=1))
        return 0

    if domain not in PILOTABLE or domain == "script":
        refuse(f"domaine {domain} hors de la maison (permis : {', '.join(sorted(PILOTABLE))}, et les scripts listés)")
    if service not in PILOTABLE[domain]:
        refuse(f"{domain}.{service} n'est pas permis (permis : {', '.join(sorted(PILOTABLE[domain]))})")
    if not targets:
        refuse("donne au moins une cible (entité ou piece:<nom>)")

    entities, refused = [], []
    for t in targets:
        if t.startswith("piece:"):
            a = house.find_area(t[6:])
            found = [e for e in house.reg if house.area.get(e) == a and e.split(".", 1)[0] == domain]
            ok = [e for e in found if house.why_not(e, domain) is None]
            if not ok:
                refuse(f"rien de pilotable en {domain} dans {house.area_name[a]}")
            entities += ok   # a room target never reaches what is not allowed
        else:
            why = house.why_not(t, domain)
            (refused.append(f"{t} : {why}") if why else entities.append(t))
    if refused:
        refuse("rien n'est parti :\n  " + "\n  ".join(refused))
    entities = sorted(set(entities))

    house.b.service(domain, service, entities, data, False)
    time.sleep(0 if FAKE else 0.8)   # let HA report the new state
    after = House(house.b)
    print(f"fait : {domain}.{service}{' ' + json.dumps(data, ensure_ascii=False) if data else ''}")
    for eid in entities:
        print(after.line(eid))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
