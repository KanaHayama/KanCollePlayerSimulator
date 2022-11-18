# -*- coding:utf-8 -*-

"""
功能：
	卸下所有在船上的装备。

使用方法：
	独立执行（使用“在新线程执行脚本文件”按钮）。

注意事项：
	在远征和在入渠的船只能卸下补强增设的装备。
	这个脚本不负责卸下基地航空队里的装备。
	如果有独占模式的配置正在执行，则会在其执行完毕后拆除装备。
	点击“终止当前任务”按钮可以停下来。
	这是很简易的脚本，没有错误处理部分，如果遇到了问题就再执行一遍吧

已知问题：
	好像改装功能在选择不在任意舰队的船时，选船好像有点问题，有时会卡住。这功能之前也没啥用，所以也没人在意实际好不好用。
		总之这个python脚本本身是没问题的，所以就发出来了。

更新记录：
	20221113 - 1.1
		适配新API
	20210614 - 1.0
		初始版本。
"""

from KancollePlayerSimulatorKaiCore import *

refreshDataTask = RefreshDataTask()
refreshDataTask.Priority += 2 # 比默认高两点的优先级
Utility.AddTask(refreshDataTask) # 先刷新一下数据

slots = (
	EquipmentSlot.Slot1,
	EquipmentSlot.Slot2,
	EquipmentSlot.Slot3,
	EquipmentSlot.Slot4,
	EquipmentSlot.Slot5,
	EquipmentSlot.SlotEx,
)

shipsState = GameState.Ships() # 优化：避免重复获取状态，所有用到此变量的地方也可以留空，但会每次获取，影响效率
equipsState = GameState.Equips() # 优化：避免重复获取状态，所有用到此变量的地方也可以留空，但会每次获取，影响效率
fleetsState = GameState.Fleets() # 优化：避免重复获取状态，所有用到此变量的地方也可以留空，但会每次获取，影响效率
repairsState = GameState.Repairs() # 优化：避免重复获取状态，所有用到此变量的地方也可以留空，但会每次获取，影响效率

shipObjs = ShipUtility.All(shipsState)
sortedShipObjs = ShipUtility.SortByLevel(shipObjs) # 优化：按等级顺序执行
sortedShipObjs = list(sortedShipObjs) # 转成list
sortedShipObjs.reverse() # 从低等级到高等级
for shipObj in sortedShipObjs:
	#if not ShipUtility.ShipLocked(shipObj): # 跳过没有上锁的船
	#	continue
	equipIds = ShipUtility.AllEquipments(shipObj)
	if len(list(equipIds)) == 0: # 跳过没装备的船
		continue
	expeditioning = ShipUtility.Expeditioning(shipObj, fleetsState)
	docking = ShipUtility.Docking(shipObj, repairsState) # ShipUtility.Repairing()会检查修复结束时间，此处不适用
	if (expeditioning or docking) and ShipUtility.ExtraEquipment(shipObj) == 0: # 跳过补强增设里没装备的远征或者入渠船
		continue
	shipId = ShipUtility.Id(shipObj)
	shipReadable = ShipUtility.HumanReadable(shipObj)
	target = {}
	if expeditioning or docking:
		target[EquipmentSlot.SlotEx] = 0
	else:
		for slot in slots:
			if ShipUtility.SlotAvailable(shipObj, slot): # 仅添加存在的装备槽，否则会在检查阶段终止执行
				target[slot] = 0
	refitTask = SimpleRefitEquipmentTask(shipId, target, shipsState, equipsState)
	refitTask.Priority += 1 # 比默认高一点的优先级
	Utility.AddTask(refitTask)

returnTask = ReturnRoomTask() # 最后再返回母港
Utility.AddTask(returnTask)
