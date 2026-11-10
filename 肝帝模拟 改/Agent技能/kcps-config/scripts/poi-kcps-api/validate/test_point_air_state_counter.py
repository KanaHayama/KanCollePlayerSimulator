"""Run embedded probe/counter code offline; no game actions are available."""
import argparse
import gzip
import json
import re
import sys
import types
import unittest
import uuid
from pathlib import Path


class JObject(dict):
    def __getitem__(self, key):
        return self.get(key)


def tokens(value):
    if isinstance(value, dict):
        return JObject({k: tokens(v) for k, v in value.items()})
    if isinstance(value, list):
        return [tokens(v) for v in value]
    return value


def block(script, name):
    match = re.search(r"# KCPS_POINT_AIR_STATE_" + name + r"_BEGIN.*?"
                      r"# KCPS_POINT_AIR_STATE_" + name + r"_END", script, re.S)
    if not match:
        raise AssertionError("Missing managed " + name)
    return match.group()


class Harness:
    def __init__(self, probe, counter):
        self.state = None
        self.messages = []
        self.errors = []
        self.workflow = types.SimpleNamespace(BattleCount=0)
        logger = types.SimpleNamespace(Info=lambda s: None, Error=self.errors.append)

        class UserEvent:
            def __init__(self, message):
                self.Message = message

        core = types.ModuleType("KancollePlayerSimulatorKaiCore")
        core.UserEvent = UserEvent
        core.GameState = types.SimpleNamespace(Battle=lambda: self.state)
        core.Utility = types.SimpleNamespace(RaiseEvent=self.send)
        system = types.ModuleType("System")
        system.Guid = types.SimpleNamespace(NewGuid=uuid.uuid4)
        self.counter = {"Logger": logger}
        self.probe = {"Logger": logger, "Workflow": self.workflow}
        saved = {name: sys.modules.get(name) for name in (core.__name__, system.__name__)}
        try:
            sys.modules[core.__name__] = core
            sys.modules[system.__name__] = system
            exec(compile(counter, "embedded-counter", "exec"), self.counter)
            exec(compile(probe, "embedded-probe", "exec"), self.probe)
        finally:
            for name, previous in saved.items():
                if previous is None:
                    sys.modules.pop(name, None)
                else:
                    sys.modules[name] = previous

    def send(self, event):
        self.messages.append(event)
        self.counter["OnFilterEvent"](event)

    def start(self):
        self.probe["OnProcess"]()

    def battle(self, seiku=1, **status):
        data = {"map": self.probe["POINT_AIR_STATE_MAP"],
                "currentCell": self.probe["POINT_AIR_STATE_VALUES"][0],
                "battle": {"packet": [{"api_kouku": {"api_stage1": {"api_disp_seiku": seiku}}}]}}
        data.update(status)
        self.state = tokens({"_status": data})
        self.probe["OnPointAirState"]()

    @property
    def count(self):
        return self.counter["_point_air_state_count"]


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--path", action="append", required=True)
parser.add_argument("--record", help="Optional local poi battle-detail .json.gz for replay")
args = parser.parse_args()
programs = []
for file in args.path:
    groups = json.loads(Path(file).read_text(encoding="utf-8-sig"))
    for group in groups:
        probe = next((w.get("Script", "") for w in group.get("List", [])
                      if "KCPS_POINT_AIR_STATE_PROBE_BEGIN" in (w.get("Script") or "")), None)
        if probe:
            counter = next(w["Script"] for w in group["List"]
                           if "KCPS_POINT_AIR_STATE_COUNTER_BEGIN" in (w.get("Script") or ""))
            programs.append((group["Name"], block(probe, "PROBE"), block(counter, "COUNTER")))
if not programs:
    raise SystemExit("No point-air-state scripts found")


class CounterTests(unittest.TestCase):
    def run_cases(self, callback):
        for name, probe, counter in programs:
            with self.subTest(config=name):
                callback(Harness(probe, counter))

    def test_missing_zero_and_string_time(self):
        def check(h):
            for status in ({}, {"time": None}, {"time": 0}, {"time": "2026-09-06T02:16:00Z"}):
                before = h.count
                h.start()
                h.battle(**status)
                self.assertEqual(h.count, before + 1)
            self.assertEqual(h.errors, [])
        self.run_cases(check)

    def test_duplicate_callback_and_delivery(self):
        def check(h):
            h.start()
            h.battle()
            h.battle()
            h.send(h.messages[0])
            self.assertEqual(h.count, 1)
        self.run_cases(check)

    def test_identical_battles_in_new_sorties(self):
        def check(h):
            required = h.counter["POINT_AIR_STATE_REQUIRED"]
            for i in range(required):
                h.start()
                h.battle(seiku=2, time=0)
                self.assertEqual(h.counter["OnAutoStop"](), i + 1 >= required)
            self.assertEqual(h.count, required)
        self.run_cases(check)

    def test_other_map_point_and_missing_battle(self):
        def check(h):
            h.start()
            h.battle(map=-1)
            h.battle(currentCell=-1)
            h.battle(battle=None)
            h.battle(battle={"packet": []})
            self.assertEqual(h.count, 0)
            self.assertFalse(h.counter["OnAutoStop"]())
        self.run_cases(check)

    def test_non_superiority_does_not_count(self):
        def check(h):
            h.start()
            for state in (0, 3, 4, 5):
                h.battle(seiku=state)
            self.assertEqual(h.count, 0)
        self.run_cases(check)

    def test_uninitialized_run_refused(self):
        def check(h):
            h.battle()
            self.assertEqual(h.count, 0)
            self.assertTrue(h.errors)
        self.run_cases(check)

    def test_stop_clears_count(self):
        def check(h):
            h.start()
            h.battle()
            h.counter["OnAutoStopped"]()
            self.assertEqual(h.count, 0)
            self.assertFalse(h.counter["OnAutoStop"]())
        self.run_cases(check)

    @unittest.skipUnless(args.record, "No replay record supplied")
    def test_real_record_with_missing_time(self):
        with gzip.open(args.record, "rt", encoding="utf-8") as stream:
            record = json.load(stream)
        matched = 0
        for name, probe, counter in programs:
            h = Harness(probe, counter)
            if h.probe["POINT_AIR_STATE_MAP"] != record["map"][0] * 10 + record["map"][1]:
                continue
            matched += 1
            h.start()
            h.battle(currentCell=record["map"][2], time=0, battle={"packet": record["packet"]})
            self.assertEqual(h.count, 1, name)
            h.probe["OnPointAirState"]()
            self.assertEqual(h.count, 1, name)
            self.assertEqual(h.errors, [])
        self.assertGreater(matched, 0)


unittest.main(argv=[sys.argv[0]], verbosity=2)
