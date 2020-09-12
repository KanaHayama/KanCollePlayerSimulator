from KancollePlayerSimulatorKaiCore import *
for equipConst in EquipmentConstUtility.All():
	external = EquipmentConstUtility.Type(equipConst)
	ingame = EquipmentConstUtility.TypeInGame(equipConst)
	if external != ingame:
		print "{0} => ex: {1}, in: {2}".format(EquipmentConstUtility.Name(equipConst), external, ingame)
print "all good"