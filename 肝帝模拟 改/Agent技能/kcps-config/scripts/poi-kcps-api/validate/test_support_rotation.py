import importlib.util
from pathlib import Path
import sys
import types
import unittest


spec = importlib.util.spec_from_file_location(
    "support_rotation", Path(__file__).parents[1] / "enable" / "support_rotation.py"
)
rotation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rotation)


def role(types_, aircraft=False):
    return {
        "ShipTypes": types_, "MinimumLevel": 80, "RequireRemodeled": 1,
        "MinimumSlots": 4 if aircraft else 3,
        "MinimumTotalCapacity": 48 if aircraft else 0,
        "MinimumAircraftPerSlot": 2 if aircraft else 0,
        "MinimumAirPower": 54 if aircraft else 0,
        "EquipmentIds": [1, 2, 3, 4] if aircraft else [],
        "AntiAir": [7, 6, 0, 0] if aircraft else [],
    }


def ship(id_, type_=7, slots=(18, 18, 18, 12), level=90, **extra):
    return dict(api_id=id_, api_lv=level, locked=True, compatible=True, remodeled=True,
                master={"api_stype": type_, "api_slot_num": len(slots), "api_maxeq": slots}, **extra)


class RotationTests(unittest.TestCase):
    def setUp(self):
        self.ships = []
        self.previous = sys.modules.get("KancollePlayerSimulatorKaiCore")
        module = types.ModuleType("KancollePlayerSimulatorKaiCore")
        module.ShipUtility = types.SimpleNamespace(
            All=lambda: self.ships, ShipLocked=lambda s: s["locked"],
            Level=lambda s: s["api_lv"], Experience=lambda s: s["api_lv"] * 100,
            Id=lambda s: s["api_id"],
        )
        module.ShipConstUtility = types.SimpleNamespace(
            ShipConst=lambda s: dict(s["master"], compatible=s["compatible"], remodeled=s["remodeled"]),
            BeforeIds=lambda m: [0] if m["remodeled"] else [],
            AllowedEquipmentConsts=lambda m, slot: [1, 2, 3, 4] if m["compatible"] else [],
        )
        module.EquipmentSlot = types.SimpleNamespace(**{"Slot" + str(i): i for i in range(1, 6)})
        sys.modules[module.__name__] = module
        rotation.SUPPORT_ROLES = {"synthetic_wing": role([7], True), "synthetic_guard": role([2])}
        rotation.OnCandidate()

    def tearDown(self):
        if self.previous is None:
            sys.modules.pop("KancollePlayerSimulatorKaiCore", None)
        else:
            sys.modules["KancollePlayerSimulatorKaiCore"] = self.previous

    def score(self, value):
        return rotation.support_candidate_score(value, value["master"], role([7], True))

    def test_airpower_boundary_and_no_proficiency_bonus(self):
        self.assertEqual(self.score(ship(1)), 54)
        self.assertIsNone(self.score(ship(1, slots=(17, 17, 18, 12))))

    def test_wrong_type_low_level_and_empty_slot(self):
        self.assertIsNone(self.score(ship(1, type_=11)))
        self.assertIsNone(self.score(ship(1, level=79)))
        self.assertIsNone(self.score(ship(1, slots=(24, 24, 12, 0))))

    def test_dynamic_destroyers_have_three_or_four_slots(self):
        for slots in ((0, 0, 0), (0, 0, 0, 0)):
            value = ship(1, type_=2, slots=slots)
            self.assertEqual(rotation.support_candidate_score(value, value["master"], role([2])), 0)

    def test_fifth_slot_does_not_inflate_guaranteed_airpower(self):
        self.assertEqual(self.score(ship(1, slots=(18, 18, 18, 12, 20))), 54)

    def test_incompatible_or_unremodeled_candidate_is_rejected(self):
        bad = ship(1, level=150); bad["compatible"] = False
        unremodeled = ship(2, level=140); unremodeled["remodeled"] = False
        self.ships = [bad, unremodeled, ship(3)]
        self.assertEqual(rotation.synthetic_wing(), 3)
        self.assertIsNone(rotation.synthetic_wing())

    def test_rejected_fatigued_candidate_can_be_followed_by_another(self):
        self.ships = [ship(10, type_=2, slots=(0, 0, 0), level=120, cond=49),
                      ship(11, type_=2, slots=(0, 0, 0, 0), level=110, cond=70)]
        selected = []
        while True:
            id_ = rotation.synthetic_guard()
            if id_ is None:
                break
            candidate = next(s for s in self.ships if s["api_id"] == id_)
            # 模拟KCPS界面对旗舰无闪的过滤。
            if candidate["cond"] > 49:
                selected.append(id_)
        self.assertEqual(selected, [11])

    def test_next_calculation_refreshes_candidate_pool(self):
        self.ships = [ship(100)]
        self.assertEqual(rotation.synthetic_wing(), 100)
        self.ships = [ship(200)]
        rotation.OnCandidate()
        self.assertEqual(rotation.synthetic_wing(), 200)

    def test_higher_level_candidate_keeps_priority(self):
        self.ships = [ship(98, level=98), ship(99, level=99)]
        self.assertEqual(rotation.synthetic_wing(), 99)

    def test_optional_fourth_slot_does_not_exclude_three_slot_ship(self):
        value = ship(7, type_=2, slots=(0, 0, 0))
        r = role([2]); r["EquipmentIds"] = [1, 2, 3, 4]; r["AntiAir"] = [0, 0, 0, 0]
        r["OptionalSlots"] = [4]
        rotation.SUPPORT_ROLES["synthetic_guard"] = r
        self.ships = [value]
        self.assertEqual(rotation.synthetic_guard(), 7)
        r["OptionalSlots"] = []
        rotation.OnCandidate()
        self.assertIsNone(rotation.synthetic_guard())

    def test_invalid_role_name_is_rejected(self):
        for name in ("OnCandidate", "for", "int"):
            rotation.SUPPORT_ROLES = {name: role([2])}
            with self.assertRaises(ValueError):
                rotation.OnCandidate()

    def test_unremodeled_is_allowed_when_plan_allows_it(self):
        rotation.SUPPORT_ROLES["synthetic_wing"]["RequireRemodeled"] = 0
        value = ship(12); value["remodeled"] = False
        self.ships = [value]
        self.assertEqual(rotation.synthetic_wing(), 12)


if __name__ == "__main__":
    unittest.main()
