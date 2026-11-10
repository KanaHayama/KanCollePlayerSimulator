"""Offline contract tests. Every ship, source and engine output below is synthetic."""
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ANALYZE = Path(__file__).resolve().parent
DATA = ANALYZE.parent / "data"


class AnalysisContractTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="kcps-analysis-fixture-")
        self.root = Path(self.temp.name).resolve()
        self.env = dict(os.environ)
        for key in ("KCPS_SETTINGS_PATH", "KCPS_WORKSPACE", "KCPS_ROUTE_OVERRIDES", "KCPS_TOKEN", "KCPS_BASE_URL"):
            self.env.pop(key, None)
        self.sources = self.root / "sources"
        self.sources.mkdir()
        self.repo = self.root / "synthetic-engine"
        paths = [
            "js/kcSHIPDATA.js", "js/kcEQDATA.js", "js/kcMAPDATA.js", "js/kcEDGES.js",
            "js/kcENEMYCOMP.js", "js/shared.js", "js/kcships.js", "js/kcsim.js",
            "js/kcsimcombined.js", "js/simulator-ui/common.js",
        ]
        for path in paths:
            dest = self.repo / path
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_text("// Synthetic fixture only.\n", encoding="utf-8")
        self.adapter = self.repo / "js/simulator-ui/sim-interface.js"
        self.adapter_text = """
global.SIM = {
    resetStats() {},
    runStats(input, callback) {
        const observed = input.fleetF.ships.map(s => ({
            hp: s.HPInit, fuel: s.fuelInit, ammo: s.ammoInit, morale: s.morale,
            ranks: s.equips.map(e => e.proficiency)
        }));
        const n = input.numSims;
        callback({
            warnings: global.fixtureWarning ? ["synthetic unsupported mechanism"] : [],
            progressTotal: n,
            result: {
                observed,
                nodes: input.nodes.map((node, i) => ({
                    num: n, taiha: 0,
                    ranks: { S: i === 0 ? 2 : 9, A: i === 0 ? 3 : 0, B: i === 0 ? 1 : 0, C: i === 0 ? 4 : 1 }
                }))
            }
        });
    }
};
"""
        self.adapter.write_text(self.adapter_text, encoding="utf-8")
        master = dict(api_name="SyntheticCarrier", api_stype=7, api_maxeq=[18, 12],
                      api_fuel_max=5, api_bull_max=5)
        ship = dict(api_ship_id=100, api_lv=50, api_maxhp=40, api_nowhp=20,
                    api_cond=32, api_fuel=3, api_bull=2, api_onslot=[18, 12],
                    api_slot=[10, 11], api_slot_ex=0, api_leng=1, api_soku=10)
        for key in ("karyoku", "raisou", "taiku", "soukou", "lucky", "kaihi", "taisen", "sakuteki"):
            ship["api_" + key] = [10, 10]
        self.snapshot = {
            "RetrievedAtJst": "2000-01-01T00:00:00+09:00", "Ships": {"1": ship},
            "Equips": {
                "10": dict(api_id=10, api_slotitem_id=200, api_level=0, api_alv=2),
                "11": dict(api_id=11, api_slotitem_id=201, api_level=0, api_alv=5),
            },
            "Constants": {
                "$ships": {"100": master},
                "$equips": {
                    "200": dict(api_name="SyntheticPlaneA", api_type=[0, 0, 6]),
                    "201": dict(api_name="SyntheticPlaneB", api_type=[0, 0, 6]),
                },
            },
        }
        initial = {
            "Kind": "Actual", "Source": "Offline synthetic fixture",
            "Supply": {"Mode": "Snapshot"}, "Hp": {"Mode": "Snapshot"},
            "Morale": {"Mode": "Snapshot"}, "AircraftCounts": {"Mode": "Snapshot"},
            "ShipAircraftProficiency": {"Mode": "SnapshotDisplay"},
            "LandBaseAircraftProficiency": {"Mode": "NotApplicable", "Reason": "合成场景不使用陆航"},
        }
        self.request = {
            "SchemaVersion": 2, "Kind": "KcpsEventSortieAnalysisRequest",
            "Name": "Synthetic fixed-route case", "Map": "99-9", "Difficulty": 1, "RouteEdges": [],
            "BattleNodes": [
                {"Label": "A", "Formation": 1, "SubOnly": False},
                {"Label": "B", "Formation": 1, "SubOnly": False},
            ],
            "Goal": {"Type": "RankAtNode", "TargetNode": "A", "MinimumRank": "A",
                     "RequiredSuccesses": 2, "IndependentRepeatedSuccesses": False},
            "Simulation": {"ModelScope": "SingleFleetFixedRoute", "NumSims": 10,
                           "Seeds": [0, 7], "InitialState": initial},
            "FleetSearch": {
                "FixedPositions": [{"Position": 1, "ShipInstanceId": 1, "Loadout": {
                    "Name": "Synthetic loadout", "MainSlots": ["SyntheticPlaneA", "SyntheticPlaneB"]
                }}],
                "VariableShipInstanceIds": [], "VariablePositions": [], "LoadoutSets": [],
                "PermuteShipOrder": False, "PermuteLoadoutAssignment": False,
                "EquipmentResolutionPositionOrder": [1],
            },
            "BonusProfiles": [{
                "Name": "VerifiedNone", "Role": "Primary", "Applicability": "NotApplicable",
                "Verified": True, "Source": "https://example.invalid/fixture-evidence",
                "LastVerifiedJst": "2000-01-01", "Multiplier": 1,
            }],
        }
        for label in ("A", "B"):
            self.write(self.sources / f"99-9-{label}-d1-enemycomps.json", {
                "Data": {"result": {"entries": [{"count": 5, "formation": 1, "mainFleet": [
                    {"id": 999, "lvl": 1, "hp": 10, "torp": 0, "armor": 0, "equips": []}
                ]}]}}
            })
        self.source_manifest = self.root / "sources.manifest.json"
        self.write(self.source_manifest, {
            "RetrievedAtJst": "2000-01-01T00:00:00+09:00",
            "Entries": [{"Url": "https://example.invalid/fixture-enemy", "Sha256": "0" * 64}],
        })
        self.snapshot_path = self.root / "snapshot.json"
        self.request_path = self.root / "request.json"
        self.write(self.snapshot_path, self.snapshot)

    def tearDown(self):
        parent = Path(tempfile.gettempdir()).resolve()
        self.assertEqual(self.root.parent, parent)
        self.assertTrue(self.root.name.startswith("kcps-analysis-fixture-"))
        self.temp.cleanup()

    def write(self, path, value):
        path.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")

    def read(self, path):
        return json.loads(path.read_text(encoding="utf-8-sig"))

    def run_script(self, name, *args, ok=True):
        result = subprocess.run(["pwsh", "-NoProfile", "-File", str(ANALYZE / name), *map(str, args)],
                                env=self.env, text=True, encoding="utf-8", errors="replace",
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, "Invalid synthetic input was accepted")
        return result

    def generate(self, request=None, label="candidates", ok=True):
        self.write(self.request_path, request or self.request)
        output = self.root / label
        result = self.run_script("New-KcpsEventSortieCandidateScenarios.ps1",
                                "-RequestPath", self.request_path, "-AccountSnapshotPath", self.snapshot_path,
                                "-SourcesDirectory", self.sources, "-OutputDirectory", output, ok=ok)
        return output, result

    def pipeline(self, request=None, label="analysis"):
        candidates, _ = self.generate(request)
        output = self.root / label
        self.run_script("Invoke-KcpsEventSortieCandidateAnalysis.ps1",
                        "-RequestPath", self.request_path,
                        "-CandidateManifestPath", candidates / "candidates.manifest.json",
                        "-SimulatorRepository", self.repo, "-SimulatorRevision", "synthetic-fixture",
                        "-OutputDirectory", output)
        result_path = self.root / (label + ".result.json")
        self.run_script("Export-KcpsEventSortieAnalysisResult.ps1",
                        "-AnalysisPath", output / "analysis.json", "-CandidateIndex", 1,
                        "-SourcesManifestPath", self.source_manifest, "-OutputPath", result_path)
        return output, result_path

    def test_actual_state_end_to_end_and_memo(self):
        output, result_path = self.pipeline()
        result = self.read(result_path)
        state = result["Assumptions"]["ResolvedShips"][0]
        self.assertEqual((state["Hp"], state["FuelFraction"], state["AmmoFraction"], state["Morale"]),
                         (20, .6, .4, 32))
        self.assertFalse(result["Assumptions"]["FullSupply"])
        self.assertEqual([e["DisplayRank"] for e in result["Assumptions"]["ShipAircraftProficiency"]["Equipment"]], [2, 5])
        observed = self.read(output / "simulation.batch.json")["results"][0]["result"]["observed"][0]
        self.assertEqual(observed, {"hp": 20, "fuel": .6, "ammo": .4, "morale": 32, "ranks": [2, 5]})
        self.assertEqual(result["Stages"][0]["Successes"], 10)  # A or better at first node, two seeds.
        self.assertNotIn("ExpectedSorties", result["Stages"][0]["Metrics"])
        self.assertIn("倍率1", result["Assumptions"]["EventBonusPolicy"])
        memo = self.run_script("KCPS-FormatSortieProbabilityMemo.ps1", "-Path", result_path, "-MemoOnly").stdout
        self.assertIn("20/40", memo)
        self.assertIn("60", memo)
        self.assertIn("2、5", memo)
        self.assertNotIn("内部熟练度120", memo)
        config = self.root / "config.json"
        self.write(config, {"List": [{"Name": "备注", "Memo": "【目标】\n合成测试"}]})
        self.run_script("Set-KcpsEventSortieAnalysisMemo.ps1", "-ConfigPath", config,
                        "-AnalysisResultPath", result_path)
        self.assertIn("20/40", self.read(config)["List"][0]["Memo"])
        try:
            from jsonschema import Draft202012Validator
        except ImportError:
            return
        Draft202012Validator(self.read(DATA / "KCPS-EventSortieAnalysisRequest.schema.json")).validate(self.request)
        Draft202012Validator(self.read(DATA / "KCPS-SortieAnalysisResult.schema.json")).validate(result)

    def test_baseline_is_explicit_and_does_not_mutate_snapshot(self):
        request = copy.deepcopy(self.request)
        state = request["Simulation"]["InitialState"]
        state["Kind"] = "Baseline"
        for key in ("Supply", "Hp", "AircraftCounts"):
            state[key] = {"Mode": "Full"}
        state["ShipAircraftProficiency"] = {"Mode": "MaxDisplay"}
        _, result_path = self.pipeline(request)
        result = self.read(result_path)
        self.assertEqual(result["Assumptions"]["StateKind"], "Baseline")
        self.assertTrue(result["Assumptions"]["FullSupply"])
        self.assertEqual(result["Assumptions"]["ResolvedShips"][0]["Hp"], 40)
        self.assertEqual(self.read(self.snapshot_path), self.snapshot)

    def test_explicit_state_preserved(self):
        request = copy.deepcopy(self.request)
        state = request["Simulation"]["InitialState"]
        state["Supply"] = {"Mode": "Explicit", "Ships": {"1": {"FuelFraction": .25, "AmmoFraction": .75}}}
        state["Hp"] = {"Mode": "Explicit", "Ships": {"1": 15}}
        state["Morale"] = {"Mode": "Explicit", "Ships": {"1": 54}}
        state["AircraftCounts"] = {"Mode": "Explicit", "Ships": {"1": [18, 12]}}
        state["ShipAircraftProficiency"] = {"Mode": "ExplicitDisplay", "Equipment": {"10": 1, "11": 6}}
        output, _ = self.generate(request)
        scenario = self.read(next(output.glob("candidate-*.json")))
        ship = scenario["fleetF"]["ships"][0]
        self.assertEqual((ship["HPInit"], ship["fuelInit"], ship["ammoInit"], ship["morale"]), (15, .25, .75, 54))
        self.assertEqual([e["proficiency"] for e in ship["equips"]], [1, 6])

    def test_unknown_and_unsupported_inputs_rejected(self):
        cases = []
        for key, value in (("Verified", False), ("Applicability", "Unknown"), ("Source", ""), ("Multiplier", 1.2)):
            request = copy.deepcopy(self.request)
            request["BonusProfiles"][0][key] = value
            cases.append(request)
        request = copy.deepcopy(self.request)
        request["Simulation"]["InitialState"]["Supply"]["Mode"] = "Full"
        cases.append(request)
        request = copy.deepcopy(self.request)
        request["Simulation"]["InitialState"]["ShipAircraftProficiency"]["Internal"] = 120
        cases.append(request)
        request = copy.deepcopy(self.request)
        request["Simulation"]["ModelScope"] = "CombinedFleet"
        cases.append(request)
        request = copy.deepcopy(self.request)
        request["BattleNodes"][0]["Smoke"] = True
        cases.append(request)
        request = copy.deepcopy(self.request)
        request["Simulation"]["UnmodeledRetreat"] = True
        cases.append(request)
        request = copy.deepcopy(self.request)
        request["FleetSearch"]["SupportFleet"] = [1]
        cases.append(request)
        for i, request in enumerate(cases):
            with self.subTest(i=i):
                output, _ = self.generate(request, label=f"invalid-{i}", ok=False)
                self.assertFalse((output / "candidates.manifest.json").exists())

    def test_missing_snapshot_state_and_nonfull_aircraft_rejected(self):
        snapshot = copy.deepcopy(self.snapshot)
        snapshot["Ships"]["1"].pop("api_nowhp")
        self.write(self.snapshot_path, snapshot)
        self.generate(label="missing-hp", ok=False)
        snapshot = copy.deepcopy(self.snapshot)
        snapshot["Ships"]["1"]["api_onslot"][0] = 10
        self.write(self.snapshot_path, snapshot)
        _, result = self.generate(label="partial-aircraft", ok=False)
        self.assertIn("非满载", result.stderr)

    def test_engine_warning_is_not_published_as_probability(self):
        self.adapter.write_text("global.fixtureWarning = true;\n" + self.adapter_text, encoding="utf-8")
        _, result_path = self.pipeline()
        result = self.read(result_path)
        self.assertFalse(result["Stages"][0]["Reliable"])
        self.assertEqual(result["Stages"][0]["Metrics"], {})
        memo = self.run_script("KCPS-FormatSortieProbabilityMemo.ps1", "-Path", result_path, "-MemoOnly").stdout
        self.assertIn("未生成可靠估算", memo)
        self.assertNotIn("单次达成：", memo)

    def test_confirmation_uses_declared_node_rank_and_input_fingerprint(self):
        output, _ = self.pipeline()
        analysis = self.read(output / "analysis.json")
        prefix = analysis["Entries"][0]["SemanticHash"]
        target = self.root / "confirmed.json"
        args = ("-AnalysisPath", output / "analysis.json", "-CandidateIndex", 1,
                "-SourcesManifestPath", self.source_manifest, "-OutputPath", target,
                "-ConfirmationBatchPath", output / "simulation.batch.json", "-ConfirmationCasePrefix", prefix)
        self.run_script("Export-KcpsEventSortieAnalysisResult.ps1", *args)
        self.assertEqual(self.read(target)["Stages"][0]["Successes"], 10)
        batch = self.read(output / "simulation.batch.json")
        batch["results"][0]["inputDigest"] = "f" * 64
        self.write(output / "simulation.batch.json", batch)
        self.run_script("Export-KcpsEventSortieAnalysisResult.ps1", *args, ok=False)

    def test_unhandled_engine_revision_fails_before_simulation(self):
        candidates, _ = self.generate()
        self.adapter.write_text(self.adapter_text.replace("fuelInit", "unsupportedFuel"), encoding="utf-8")
        output = self.root / "unsupported-engine"
        self.run_script("Invoke-KcpsEventSortieCandidateAnalysis.ps1",
                        "-RequestPath", self.request_path,
                        "-CandidateManifestPath", candidates / "candidates.manifest.json",
                        "-SimulatorRepository", self.repo, "-SimulatorRevision", "synthetic-fixture",
                        "-OutputDirectory", output, ok=False)
        self.assertFalse((output / "analysis.json").exists())

    def test_verified_damage_multipliers_are_explicit_per_ship(self):
        request = copy.deepcopy(self.request)
        profile = request["BonusProfiles"][0]
        profile.pop("Multiplier")
        profile.update(Applicability="Applicable", Model="DamageMultiplier",
                       ShipBonuses={"1": {"DefaultDamage": 1.2, "ByNode": {"A": 1.5}}})
        output, _ = self.generate(request)
        ship = self.read(next(output.glob("candidate-*.json")))["fleetF"]["ships"][0]
        self.assertEqual(ship["bonuses"]["bonusDmg"], 1.2)
        self.assertEqual(ship["bonusesByNode"]["1"]["bonusDmg"], 1.5)
        profile["ShipBonuses"] = {}
        self.generate(request, label="missing-ship-bonus", ok=False)

    def test_changed_candidates_and_reused_batches_are_rejected(self):
        output, _ = self.pipeline()
        batch_path = output / "simulation.batch.json"
        batch = self.read(batch_path)
        batch["results"].pop()
        self.write(batch_path, batch)
        candidates = self.root / "candidates"
        args = ("-RequestPath", self.request_path,
                "-CandidateManifestPath", candidates / "candidates.manifest.json",
                "-SimulatorRepository", self.repo, "-SimulatorRevision", "synthetic-fixture",
                "-OutputDirectory", output, "-ReuseBatch")
        self.run_script("Invoke-KcpsEventSortieCandidateAnalysis.ps1", *args, ok=False)
        scenario_path = next(candidates.glob("candidate-*.json"))
        scenario = self.read(scenario_path)
        scenario["fleetF"]["ships"][0]["fuelInit"] = 1
        self.write(scenario_path, scenario)
        result = self.run_script("Invoke-KcpsEventSortieCandidateAnalysis.ps1", *args, ok=False)
        self.assertIn("被修改", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)

