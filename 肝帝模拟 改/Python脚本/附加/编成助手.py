# -*- coding: utf-8 -*-

"""
功能：
	选取和过滤舰船

使用方法：
	附加在需要的执行单元上（如基础编成舰队）
	在填写函数的地方填写需要的函数名（见范例配置中的示例）

更新记录：
	20200211 - 1.3
		修复Bug
	20200210 - 1.2
		修复Bug
	20200209 - 1.1
		多处优化
	20200208 - 1.0
		随KCPS1.3.3.0发布
"""

# 导入
from KancollePlayerSimulatorKaiCore import *
import time
import itertools
import math

# 常数
DLC_CONST_ID = EquipmentConstUtility.Id( \
		[obj for obj in EquipmentConstUtility.All() \
		if EquipmentConstUtility.Name(obj) == "大発動艇"][0]) #大发的ID，能带特大发的船大发也能带

# 属性获取助手
def getConst(shipObj):
	return ShipConstUtility.ShipConst(shipObj)

def getId(shipObj):
	return ShipUtility.Id(shipObj)

def getLevel(shipObj):
	return ShipUtility.Level(shipObj)

def getExperience(shipObj):
	return ShipUtility.Experience(shipObj)

def getAllowedEquipIds(shipConstObj):
	return ShipConstUtility.AllowedEquipmentConsts(shipConstObj, EquipmentSlot.Slot1)

def getBeforeUpgradeIds(shipConstObj):
	return ShipConstUtility.BeforeIds(shipConstObj)

def getIds(shipObjs):
	return [getId(shipObj) for shipObj in shipObjs]

# 复杂过滤器（界面里没提供的）
def filterDlcEquiptable(shipObjs): # 可以带大发的
	return [shipObj for shipObj in shipObjs if DLC_CONST_ID in getAllowedEquipIds(getConst(shipObj))]

def filterDlcNotEquiptable(shipObjs): # 不可以带大发的
	return [shipObj for shipObj in shipObjs if DLC_CONST_ID not in getAllowedEquipIds(getConst(shipObj))]

def filterLevelRange(shipObjs, low, high): # 筛选等级在范围内的船
	return [shipObj for shipObj in shipObjs if low <= getLevel(shipObj) and getLevel(shipObj) <= high]

def filterUpgraded(shipObjs): # 筛选至少一改过后的
	return [shipObj for shipObj in shipObjs if len([i for i in getBeforeUpgradeIds(getConst(shipObj))]) > 0]

def filterNot99(shipObjs): # 排除99级的
	return [shipObj for shipObj in shipObjs if getLevel(shipObj) != 99]

def filterLowLevelByProportion(shipObjs, proportion): # 按比例保留低等级舰船，传入的数组应当是升序的
	return shipObjs[:int(math.ceil(len(shipObjs) * proportion))]

# 排序
def sortByExperienceAsc(shipObjs): # 经验由低到高排序
	return sorted(shipObjs, key=lambda x: getExperience(x))

def sortByIdAsc(shipObjs): # ID由低到高排序
	return sorted(shipObjs, key=lambda x: getId(x))

# 舰船集合（只列出了普通远征用得着的；自行解除注释；舰船之后还会依据界面中的设置过滤一遍）
s = {}
def buildSets():
	print("正在更新舰船集合，这需要一些时间")
	global s
	s.clear()
	s["all"] = sortByExperienceAsc(ShipUtility.All()) # 所有舰船，经验升序
	s["de"] = [shipObj for shipObj in s["all"] if ShipUtility.Type(shipObj) == ShipType.Escort] # DE
	s["dd"] = [shipObj for shipObj in s["all"] if ShipUtility.Type(shipObj) == ShipType.Destroyer] # DD
	s["cl"] = [shipObj for shipObj in s["all"] if ShipUtility.Type(shipObj) == ShipType.LightCruiser] # CL
	s["av"] = [shipObj for shipObj in s["all"] if ShipUtility.Type(shipObj) == ShipType.SeaplaneCarrier] # AV
	# s["ca"] = [shipObj for shipObj in s["all"] if ShipUtility.Type(shipObj) == ShipType.HeavyCruiser] # CA
	# s["cav"] = [shipObj for shipObj in s["all"] if ShipUtility.Type(shipObj) == ShipType.AircraftCruiser] # CAV
	# s["bbc"] = [shipObj for shipObj in s["all"] if ShipUtility.Type(shipObj) == ShipType.BattleCruiser] # BB（高速）
	# s["bb"] = [shipObj for shipObj in s["all"] if ShipUtility.Type(shipObj) in (ShipType.Battleship, ShipType.SuperDreadnoughts)] # BB（低速）
	# s["bbv"] = [shipObj for shipObj in s["all"] if ShipUtility.Type(shipObj) == ShipType.AviationBattleship] # BBV
	# s["cv"] = [shipObj for shipObj in s["all"] if ShipUtility.Type(shipObj) == ShipType.AircraftCarrier] # CV
	# s["cvb"] = [shipObj for shipObj in s["all"] if ShipUtility.Type(shipObj) == ShipType.ArmouredAircraftCarrier] # CVB
	# s["cvl"] = [shipObj for shipObj in s["all"] if ShipUtility.Type(shipObj) == ShipType.LightAircraftCarrier] # CVL
	# s["ss"] = [shipObj for shipObj in s["all"] if ShipUtility.Type(shipObj) == ShipType.Submarine] # SS
	# s["ssv"] = [shipObj for shipObj in s["all"] if ShipUtility.Type(shipObj) == ShipType.AircraftCarryingSubmarine] # SSV
	# s["as"] = [shipObj for shipObj in s["all"] if ShipUtility.Type(shipObj) == ShipType.SubmarineTender] # AS
	# s["ar"] = [shipObj for shipObj in s["all"] if ShipUtility.Type(shipObj) == ShipType.RepairShip] # AR
	# s["ao"] = [shipObj for shipObj in s["all"] if ShipUtility.Type(shipObj) == ShipType.FleetOiler] # AO
	# s["ct"] = [shipObj for shipObj in s["all"] if ShipUtility.Type(shipObj) == ShipType.TrainingCruiser] # CT
	# s["clt"] = [shipObj for shipObj in s["all"] if ShipUtility.Type(shipObj) == ShipType.TorpedoCruiser] # CLT
	s["av_upgraded"] = filterUpgraded(s["av"]) # 至少一改之后的AV
	s["cl_upgraded"] = filterUpgraded(s["cl"]) # 至少一改之后的CL
	s["dd_upgraded"] = filterUpgraded(s["dd"]) # 至少一改之后的DD
	s["de_upgraded"] = filterUpgraded(s["de"]) # 至少一改之后的DE
	s["av_idle"] = filterLowLevelByProportion(s["av_upgraded"], 0.9) # 只选用90%低等级的AV（高等级用作出击，避免误入渠）
	s["cl_idle"] = filterLowLevelByProportion(s["cl_upgraded"], 0.9) # 只选用90%低等级的CL（高等级用作出击，避免误入渠）
	s["dd_idle"] = filterLowLevelByProportion(s["dd_upgraded"], 0.9) # 只选用90%低等级的DD（高等级用作出击，避免误入渠）
	s["de_idle"] = filterLowLevelByProportion(s["de_upgraded"], 0.9) # 只选用90%低等级的DE（高等级用作出击，避免误入渠）
	s["cl_dlc"] = filterDlcEquiptable(s["cl_idle"]) # 可以带大发的CL
	s["dd_dlc"] = filterDlcEquiptable(s["dd_idle"]) # 可以带大发的DD
	s["cl_no_dlc"] = filterDlcNotEquiptable(s["cl_idle"]) # 不可以带大发的CL
	s["dd_no_dlc"] = filterDlcNotEquiptable(s["dd_idle"]) # 不可以带大发的DD
	s["av_leveling"] = filterNot99(s["av_idle"]) # 需要靠远征练级的AV
	s["cl_leveling"] = filterNot99(s["cl_no_dlc"]) # 需要靠远征练级的CL
	s["dd_leveling"] = filterNot99(s["dd_no_dlc"]) # 需要靠远征练级的DD
	s["de_leveling"] = filterNot99(filterUpgraded(s["de_idle"])) # 需要靠远征练级的DE（至少一改的）
	s["expedition"] = list(itertools.chain(s["dd_dlc"], s["cl_dlc"], s["av_leveling"], s["cl_leveling"], s["dd_leveling"], s["de_leveling"])) # 全自动范例中用于远征的船
	s["disposable"] = sortByIdAsc(filterLevelRange(s["dd"], 1, 3)) # 狗粮

# 迭代器
it = {}
def initialize():
	buildSets()
	global it
	it.clear()

def getIter(key):
	global s
	global it
	if len(s) == 0: # TODO，以后更新时删掉这个
		initialize()
	if key not in it: # 创建迭代器
		it[key] = iter(getIds(s[key]))
	return it[key]

def getOne(key):
	try:
		return next(getIter(key))
	except StopIteration:
		it.pop(key)
		return None # 返回-1也行

# 导出函数
def OnCandidate(): # 编成计算时会调用
	global s
	global it
	buildSets()
	it.clear()

dd_dlc = lambda : getOne("dd_dlc")
cl_dlc = lambda : getOne("cl_dlc")
av_leveling = lambda : getOne("av_leveling")
cl_leveling = lambda : getOne("cl_leveling")
dd_leveling = lambda : getOne("dd_leveling")
de_leveling = lambda : getOne("de_leveling")

def disposable(): # 因为狗粮受拆船影响大，所以需要经常更新候选
	key = "disposable"
	id = getOne(key)
	iterEnd = id is None
	isInvalidId = not iterEnd and ShipUtility.Ship(id) is None # 查找不到船了，就说明解体过一次
	if iterEnd or isInvalidId:
		global s
		s = {}
		global it
		it.pop(key, None)
		if isInvalidId:
			id = getOne(key)
	return id

def dock_expedition(id): # 用于刷闪修理防止入渠不用于远征的船
	global s
	if len(s) == 0:
		initialize()
	return id in getIds(s["expedition"])