import math
import keyword


def support_candidate_score(ship, master, role):
    # 只限定舰种、练度和槽位能力，不限定船名或实例。
    if int(str(master["api_stype"])) not in role["ShipTypes"]:
        return None
    if int(str(ship["api_lv"])) < role["MinimumLevel"]:
        return None
    slots = [int(str(value)) for value in master["api_maxeq"]]
    count = int(str(master["api_slot_num"]))
    if count < role["MinimumSlots"]:
        return None
    if role["MinimumTotalCapacity"] and sum(slots) < role["MinimumTotalCapacity"]:
        return None
    if role["MinimumAircraftPerSlot"] and any(
        slots[i] < role["MinimumAircraftPerSlot"]
        for i in range(min(count, len(role["EquipmentIds"])))
    ):
        return None
    required_slots = [i + 1 for i in range(len(role["EquipmentIds"])) if i + 1 not in role.get("OptionalSlots", [])]
    if required_slots and count < max(required_slots):
        return None
    power = sum(int(aa * math.sqrt(slots[i])) for i, aa in enumerate(role["AntiAir"]) if i < count)
    return power if power >= role["MinimumAirPower"] else None


_support_iters = {}


def OnCandidate():
    _support_iters.clear()
    for key in SUPPORT_ROLES:
        if not key.isidentifier() or keyword.iskeyword(key) or key.startswith("_") or key in {"OnCandidate", "support_candidate_score", "register_support_roles", "math", "keyword", "SUPPORT_ROLES", "int", "str", "list", "iter", "next", "sum", "any", "enumerate", "range", "getattr", "globals", "ValueError"}:
            raise ValueError("Invalid support role name: " + key)
        globals()[key] = lambda role_key=key: _support_next(role_key)


def _support_next(key):
    from KancollePlayerSimulatorKaiCore import ShipUtility, ShipConstUtility, EquipmentSlot

    if key not in _support_iters:
        role = SUPPORT_ROLES[key]
        candidates = []
        for ship in ShipUtility.All():
            if not ShipUtility.ShipLocked(ship):
                continue
            master = ShipConstUtility.ShipConst(ship)
            score = support_candidate_score(ship, master, role)
            if score is None or (role.get("RequireRemodeled", False) and not list(ShipConstUtility.BeforeIds(master))):
                continue
            # 每个必需槽都要能带本位置配装，防止换到不兼容的轻母。
            compatible = True
            for i, equipment_id in enumerate(role["EquipmentIds"]):
                if i + 1 > int(str(master["api_slot_num"])) and i + 1 in role.get("OptionalSlots", []):
                    continue
                slot = getattr(EquipmentSlot, "Slot" + str(i + 1))
                allowed = ShipConstUtility.AllowedEquipmentConsts(master, slot)
                if equipment_id not in [int(value) for value in allowed]:
                    compatible = False
                    break
            expansion_id = role.get("ExpansionEquipmentId", 0)
            if compatible and expansion_id and int(str(ship["api_slot_ex"])) != 0:
                allowed = ShipConstUtility.AllowedEquipmentConsts(master, EquipmentSlot.SlotEx)
                compatible = expansion_id in [int(value) for value in allowed]
            if compatible:
                candidates.append(ship)
        # 由界面继续过滤疲劳、入渠、远征及其他舰队占用。
        candidates.sort(key=lambda ship: (
            ShipUtility.Experience(ship), ShipUtility.Level(ship)
        ), reverse=True)
        _support_iters[key] = iter(ShipUtility.Id(ship) for ship in candidates)
    try:
        return next(_support_iters[key])
    except StopIteration:
        _support_iters.pop(key, None)
        return None

