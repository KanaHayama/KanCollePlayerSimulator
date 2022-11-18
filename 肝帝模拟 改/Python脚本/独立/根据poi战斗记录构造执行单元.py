# -*- coding: utf-8 -*-

"""
功能：
	解析剪贴板中的poi战斗记录数据，并自动生成相应的执行单元（编成、改装）。
	可以用来组合范例配置和以往的出击记录来创建你自己的配置。
	这也相当于一定程度地免费提供了存取配置这一付费功能。
	如遇错误，错误信息会打印到控制台。

使用方法：
	新建一个空的配置，并确保该配置在配置列表的最下方
	打开poi航海日志中你想要解析的战斗记录
	点击“复制数据”将数据复制到剪贴板
	使用“关于”中的“在新线程执行脚本”功能运行本脚本

更新记录：
	20221118 - 1.2
		适配新的执行单元创建流程。
	20200128 - 1.1
		适配1.3.3.0修改后的类结构。
	20200124 - 1.0
		生成单舰队编成和改装执行单元。
		使用了尚未发布的版本中的特性（①__name__；②Dispatcher；③STAThread），所以当前最新版1.3.2.1不可使用。
"""

import clr
clr.AddReference('System.Windows.Forms')
from System.Windows.Forms import Clipboard # 貌似没法引入System.Windows.Clipboard，所以就用Forms里的凑合吧

from KancollePlayerSimulatorKaiCore import *
from KancollePlayerSimulatorKai import *
import json

def createMemoWorkflow(obj):
	memo = MemoWorkflow()
	memo.Name = "战斗数据"
	memo.Memo = json.dumps(obj, indent=4, separators=(',', ': '))
	return memo

def createBasicOrganizeFleetWorkflow(data, fleet):
	orgnize = BasicOrganizeFleetWorkflow()
	orgnize.Fleet = fleet
	orgnize.Name = "编成第%i舰队" % fleet
	for shipData in data:
		if shipData is not None:
			shipConstId = shipData["api_ship_id"]
			selection = OrganizeFleetSelectShipStrategy()
			selection.Type = SelectStrategyType.NameLvDescending # 覆盖默认值
			selection.Value = ShipConstUtility.Name(ShipConstUtility.ShipConst(shipConstId)) # 使用名称的话泛用性能会更强一点
			position = OrganizeFleetPositionStrategy()
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

def createBasicCombinedFleetWorkflow(typeId):
	combine = BasicCombinedFleetWorkflow()
	combine.CombinedFleetType = CombinedFleetType(typeId)
	return combine

def createBasicRefitEquipmentWorkflow(data, fleet):
	def createSlot(equipConstId, slotEnum):
			slot = RefitEquipmentSelectSlotStrategy()
			slot.Slot = slotEnum
			equipment = RefitEquipmentSelectEquipmentStrategy()
			try:
				equipment.SelectValue = EquipmentConstUtility.Name(EquipmentConstUtility.EquipmentConst(equipConstId))
			except:
				equipment.SelectValue = "无法确定名称的装备"
				print("有无法确定名称的装备")
			slot.Equipments.Add(equipment)
			return slot
	refit = BasicRefitEquipmentWorkflow()
	refit.Name = "改装第%i舰队" % fleet
	for shipIdx in range(len(data)):
		shipData = data[shipIdx]
		if shipData is not None:
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
		print("请先手动创建一个空配置并放置到配置列表的末尾") # Utility.Groups.Add方法受保护（否则付费功能就没意义了），外部无法调用。
		return
	group = Utility.Groups[Utility.Groups.Count - 1]
	
	# 构造备忘执行单元
	memo = createMemoWorkflow(battleData)
	Dispatcher.Invoke(lambda :group.Add(memo)) # 直接在独立线程添加执行单元会报错
	
	# 构造编成执行单元
	mainFleet = createBasicOrganizeFleetWorkflow(battleData["fleet"]["main"], 1)
	Dispatcher.Invoke(lambda :group.Add(mainFleet))
	if battleData["fleet"]["escort"] is not None: # TODO:尚未测试
		# 添加伴随舰队
		escortFleet = createBasicOrganizeFleetWorkflow(battleData["fleet"]["escort"], 2)
		Dispatcher.Invoke(lambda :group.Add(escortFleet))
		# 添加组成联合舰队
		combine = createBasicCombinedFleetWorkflow(battleData["fleet"]["type"])
		Dispatcher.Invoke(lambda :group.Add(combine))
	
	# 构造改装执行单元
	mainRefit = createBasicRefitEquipmentWorkflow(battleData["fleet"]["main"], 1)
	Dispatcher.Invoke(lambda :group.Add(mainRefit))
	if battleData["fleet"]["escort"] is not None: # TODO:尚未测试
		escortRefit = createBasicRefitEquipmentWorkflow(battleData["fleet"]["escort"], 2)
		Dispatcher.Invoke(lambda :group.Add(escortRefit))

	# 注册执行单元
	memo.InitializeServices(Program.CurrentHost.Services)
	mainFleet.InitializeServices(Program.CurrentHost.Services)
	mainRefit.InitializeServices(Program.CurrentHost.Services)

if __name__ == "__main__":
	main()