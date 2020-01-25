# -*- coding: utf-8 -*-

"""
功能：
	解析剪贴板中的poi战斗记录数据，并自动生成相应的执行单元。
	相当于一定程度地免费提供了读取配置这一付费功能，其实再加点东西就能完全替代读取配置功能了……

使用方法：
	新建一个空的配置，并确保该配置在配置列表的最下方
	选中poi中的战斗记录
	点击“复制数据”
	使用“关于”中的“在新线程执行脚本”功能运行本脚本

更新记录：
	20200124 - 1.0
		生成单舰队编成和改装执行单元。
		使用了尚未发布的版本中的特性，所以当前最新版1.3.2.1不可使用。
"""

import clr
clr.AddReference('System.Windows.Forms')
from System.Windows.Forms import Clipboard

from KancollePlayerSimulatorKaiCore import *
from KancollePlayerSimulatorKai import *
import json

def createMemoWorkflow(raw):
	memo = MemoWorkflow()
	memo.Name = "战斗数据"
	memo.Memo = raw
	return memo

def createBasicOrganizeFleetWorkflow(data, fleet):
	orgnize = BasicOrganizeFleetWorkflow()
	orgnize.Fleet = fleet
	orgnize.Name = "编成第%i舰队" % fleet
	for shipData in data:
		shipConstId = shipData["api_ship_id"]
		selection = BasicOrganizeFleetWorkflow.SelectStrategy() # 以后可能会从BasicOrganizeFleetWorkflow里拿出来
		selection.Type = SelectStrategyType.NameLvDescending # 覆盖默认值
		selection.Value = ShipConstUtility.Name(ShipConstUtility.ShipConst(shipConstId)) # 使用名称的话泛用性能会更强一点
		position = BasicOrganizeFleetWorkflow.PositionSetting() # 以后可能会从BasicOrganizeFleetWorkflow里拿出来
		position.SkipWrongShips = False # 覆盖默认值
		position.SkipShipsInThisFleet = False # 覆盖默认值
		position.SkipShipsInOtherFleets = False # 覆盖默认值
		position.SkipRepairingShips = False # 覆盖默认值
		position.SkipExpeditioningShips = False # 覆盖默认值
		position.SkipHpInRangeFlag = False # 覆盖默认值
		position.SkipMoraleInRangeFlag = False # 覆盖默认值
		position.SkipLocked = False # 覆盖默认值
		position.SkipUnlocked = False # 覆盖默认值
		position.SkipNoConventionalEquipments = False # 覆盖默认值
		position.EnableScriptFilter = False # 覆盖默认值
		position.Selections.Add(selection)
		orgnize.Positions.Add(position)
	return orgnize

def createBasicRefitEquipmentWorkflow(data, fleet):
	def createSlot(equipConstId, slotEnum):
			slot = RefitEquipmentSelectSlotStrategy()
			slot.Slot = slotEnum
			equipment = RefitEquipmentSelectEquipmentStrategy()
			try:
				equipment.SelectValue = EquipmentConstUtility.Name(EquipmentConstUtility.EquipmentConst(equipConstId))
			except:
				equipment.SelectValue = "没有找到装备，无法确定装备名"
			slot.Equipments.Add(equipment)
			return slot
	refit = BasicRefitEquipmentWorkflow()
	refit.Name = "改装第%i舰队" % fleet
	for shipIdx in range(len(data)):
		shipData = data[shipIdx]
		ship = RefitEquipmentSelectShipStrategy()
		ship.Fleet = SelectableFleet(fleet)
		ship.SelectMethod = RefitEquipmentSelectShipMethod.Position
		ship.SelectValue = str(shipIdx + 1)
		for equipIdx in range(len(shipData["poi_slot"])): # 通常装备槽
			equipObj = shipData["poi_slot"][equipIdx]
			if equipObj is not None:
				slot = createSlot(equipObj["api_slotitem_id"], EquipmentSlot(equipIdx + 1))
				ship.Slots.Add(slot)
		if shipData["poi_slot_ex"] is not None: # 增强补设装备槽
			slot = createSlot(shipData["poi_slot_ex"]["api_slotitem_id"], EquipmentSlot.SlotEx)
			ship.Slots.Add(slot)
		refit.Ships.Add(ship)
	return refit

def main():
	# 解析战斗数据
	battleDataRaw = Clipboard.GetText()
	try:
		global battleData
		battleData = json.loads(battleDataRaw)
	except ValueError:
		print("无法解析战斗数据，请确认数据已经复制到剪贴板")
		return
	
	# 检查最后一个配置
	if Utility.Groups.Count == 0 or Utility.Groups[Utility.Groups.Count - 1].Count != 0:
		print("请先手动创建一个空配置并放置到配置列表的末尾")
		return
	group = Utility.Groups[Utility.Groups.Count - 1]
	
	# 构造备忘执行单元
	memo = createMemoWorkflow(battleDataRaw)
	Dispatcher.Invoke(lambda :group.Add(memo)) # 直接在独立线程添加执行单元会报错
	
	# 构造编成执行单元
	mainFleet = createBasicOrganizeFleetWorkflow(battleData["fleet"]["main"], 1)
	Dispatcher.Invoke(lambda :group.Add(mainFleet))
	if battleData["fleet"]["escort"] is not None: # TODO:尚未测试
		# 添加伴随舰队
		escortFleet = createBasicOrganizeFleetWorkflow(battleData["fleet"]["escort"], 2)
		Dispatcher.Invoke(lambda :group.Add(escortFleet))
		# 添加组成联合舰队
		combine = BasicCombinedFleetWorkflow()
		combine.CombinedFleetType = CombinedFleetType(battleData["fleet"]["type"])
		Dispatcher.Invoke(lambda :group.Add(combine))
	
	# 构造改装执行单元
	mainRefit = createBasicRefitEquipmentWorkflow(battleData["fleet"]["main"], 1)
	Dispatcher.Invoke(lambda :group.Add(mainRefit))
	if battleData["fleet"]["escort"] is not None: # TODO:尚未测试
		escortRefit = createBasicRefitEquipmentWorkflow(battleData["fleet"]["escort"], 2)
		Dispatcher.Invoke(lambda :group.Add(escortRefit))

if __name__ == "__main__":
	main()