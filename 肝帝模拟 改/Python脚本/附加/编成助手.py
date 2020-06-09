# -*- coding: utf-8 -*-

"""
功能：
	选取和过滤舰船

使用方法：
	附加在需要的执行单元上（如基础编成舰队）
	在填写函数的地方填写需要的函数名（见范例配置中的示例）

更新记录：
	20200527 - 2.0
		延迟初始化
	20200211 - 1.3
		修复Bug
	20200210 - 1.2
		修复Bug
	20200209 - 1.1
		多处优化
	20200208 - 1.0
		随KCPS1.3.3.0发布
"""

#===================================================#
#                                                   #
#                        导入                       #
#                                                   #
#===================================================#
from KancollePlayerSimulatorKaiCore import *
import time
import itertools
import math

#===================================================#
#                                                   #
#                        常量                       #
#                                                   #
#===================================================#
def getEquipConstId(name):
	return EquipmentConstUtility.Id([obj for obj in EquipmentConstUtility.All() if EquipmentConstUtility.Name(obj) == name][0])

DLC_CONST_ID = getEquipConstId("大発動艇") #大发的ID，能带特大发的船大发也能带
KHT_CONST_ID = getEquipConstId("甲標的 甲型")

#===================================================#
#                                                   #
#                        工具                       #
#                                                   #
#===================================================#
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
def filterEquiptable(shipObjs, equip_const_id): # 可以带某装备的
	return [shipObj for shipObj in shipObjs if equip_const_id in getAllowedEquipIds(getConst(shipObj))]

def filterNotEquiptable(shipObjs, equip_const_id): # 不可以带某装备的
	return [shipObj for shipObj in shipObjs if equip_const_id not in getAllowedEquipIds(getConst(shipObj))]

def filterLevelRange(shipObjs, low, high): # 筛选等级在范围内的船
	return [shipObj for shipObj in shipObjs if low <= getLevel(shipObj) and getLevel(shipObj) <= high]

def filterUpgraded(shipObjs): # 筛选至少一改过后的
	return [shipObj for shipObj in shipObjs if len([i for i in getBeforeUpgradeIds(getConst(shipObj))]) > 0]

def filterNotUpgraded(shipObjs): # 筛选没有一改的
	return [shipObj for shipObj in shipObjs if len([i for i in getBeforeUpgradeIds(getConst(shipObj))]) == 0]

def filterLevelAt(shipObjs, level): # 筛选对应等级
	return [shipObj for shipObj in shipObjs if getLevel(shipObj) == level]

def filterLevelNotAt(shipObjs, level): # 筛选非对应等级
	return [shipObj for shipObj in shipObjs if getLevel(shipObj) != level]

def filterLevelNotAt99(shipObjs): # 筛选非99级
	return filterLevelNotAt(shipObjs, 99)

def filterLevelAbove(shipObjs, level): # 筛选对应等级以上
	return [shipObj for shipObj in shipObjs if getLevel(shipObj) > level]

def filterLevelBelow(shipObjs, level): # 筛选对应等级以下
	return [shipObj for shipObj in shipObjs if getLevel(shipObj) < level]

def filterFrontProportion(shipObjs, proportion): # 保留前一定比例的船
	return shipObjs[:int(math.ceil(len(shipObjs) * proportion))]

def filterBackProportion(shipObjs, proportion): # 保留后一定比例的船
	return shipObjs[-int(math.ceil(len(shipObjs) * proportion)):]

# 排序
def sortByExperienceAsc(shipObjs): # 经验由低到高排序
	return sorted(shipObjs, key=lambda x: getExperience(x))

def sortByExperienceDesc(shipObjs): # 经验由高到低排序
	return sorted(shipObjs, key=lambda x: getExperience(x), reverse=True)

def sortByIdAsc(shipObjs): # ID由低到高排序
	return sorted(shipObjs, key=lambda x: getId(x))

def sortByLevelingPreference(shipObjs): # 以提升整体等级为目的的排序[改后99级以下，改后99级以上，改前99级以上，改前99级以下，改后99级，改前99级]（同类内等级升序）
	shipObjs = sortByExperienceAsc(shipObjs)
	upgraded = filterUpgraded(shipObjs)
	notUpgraded = [shipObj for shipObj in shipObjs if shipObj not in upgraded]
	upgraded_below = filterLevelBelow(upgraded, 99)
	upgraded_above = filterLevelAbove(upgraded, 99)
	upgraded_99 = filterLevelAt(upgraded, 99)
	notUpgraded_below = filterLevelBelow(notUpgraded, 99)
	notUpgraded_above = filterLevelAbove(notUpgraded, 99)
	notUpgraded_99 = filterLevelAt(notUpgraded, 99)
	return upgraded_below + upgraded_above + notUpgraded_above + notUpgraded_below + upgraded_99 + notUpgraded_99

def sortByForcePreference(shipObjs):
	level_not_99 = filterLevelNotAt99(shipObjs)
	level99 = [shipObj for shipObj in shipObjs if shipObj not in level_not_99]
	return sortByExperienceDesc(level_not_99) + level99

# 舰船集合（只列出了普遍用得着的；返回的舰船之后还会依据界面中的设置过滤一遍）
shipsState = None # ShipUtility的一个参数，不提供也可以，但会每次都查询这个值，此处复用的话可以加速执行
lambdas = {}
lists = {}

def getList(key):
	global lambdas
	global lists
	if key not in lists:
		lists[key] = lambdas[key]()
	return lists[key]

lambdas["all"] = lambda: sortByExperienceAsc(ShipUtility.All(shipsState)) # 所有舰船，经验升序
lambdas["de"] = lambda: [shipObj for shipObj in getList("all") if ShipUtility.Type(shipObj) == ShipType.Escort] # DE
lambdas["dd"] = lambda: [shipObj for shipObj in getList("all") if ShipUtility.Type(shipObj) == ShipType.Destroyer] # DD
lambdas["cl"] = lambda: [shipObj for shipObj in getList("all") if ShipUtility.Type(shipObj) == ShipType.LightCruiser] # CL
lambdas["av"] = lambda: [shipObj for shipObj in getList("all") if ShipUtility.Type(shipObj) == ShipType.SeaplaneCarrier] # AV
lambdas["ca"] = lambda: [shipObj for shipObj in getList("all") if ShipUtility.Type(shipObj) == ShipType.HeavyCruiser] # CA
lambdas["cav"] = lambda: [shipObj for shipObj in getList("all") if ShipUtility.Type(shipObj) == ShipType.AircraftCruiser] # CAV
lambdas["ca_cav"] = lambda: sortByExperienceAsc(itertools.chain(getList("ca"), getList("cav"))) # CA 和 CAV
lambdas["bbc"] = lambda: [shipObj for shipObj in getList("all") if ShipUtility.Type(shipObj) == ShipType.BattleCruiser] # BB（高速）
lambdas["bb"] = lambda: [shipObj for shipObj in getList("all") if ShipUtility.Type(shipObj) in (ShipType.Battleship, ShipType.SuperDreadnoughts)] # BB（低速）
lambdas["bbv"] = lambda: [shipObj for shipObj in getList("all") if ShipUtility.Type(shipObj) == ShipType.AviationBattleship] # BBV
lambdas["cv"] = lambda: [shipObj for shipObj in getList("all") if ShipUtility.Type(shipObj) == ShipType.AircraftCarrier] # CV
lambdas["cvb"] = lambda: [shipObj for shipObj in getList("all") if ShipUtility.Type(shipObj) == ShipType.ArmouredAircraftCarrier] # CVB
lambdas["cv_cvb"] = lambda: sortByExperienceAsc(itertools.chain(getList("cv"), getList("cvb"))) # CV 和 CVB
lambdas["cvl"] = lambda: [shipObj for shipObj in getList("all") if ShipUtility.Type(shipObj) == ShipType.LightAircraftCarrier] # CVL
lambdas["ss"] = lambda: [shipObj for shipObj in getList("all") if ShipUtility.Type(shipObj) == ShipType.Submarine] # SS
lambdas["ssv"] = lambda: [shipObj for shipObj in getList("all") if ShipUtility.Type(shipObj) == ShipType.AircraftCarryingSubmarine] # SSV
lambdas["ss_ssv"] = lambda: sortByExperienceAsc(itertools.chain(getList("ss"), getList("ssv"))) # SS 和 SSV
lambdas["as"] = lambda: [shipObj for shipObj in getList("all") if ShipUtility.Type(shipObj) == ShipType.SubmarineTender] # AS
lambdas["ar"] = lambda: [shipObj for shipObj in getList("all") if ShipUtility.Type(shipObj) == ShipType.RepairShip] # AR
lambdas["ao"] = lambda: [shipObj for shipObj in getList("all") if ShipUtility.Type(shipObj) == ShipType.FleetOiler] # AO
lambdas["ct"] = lambda: [shipObj for shipObj in getList("all") if ShipUtility.Type(shipObj) == ShipType.TrainingCruiser] # CT
lambdas["clt"] = lambda: [shipObj for shipObj in getList("all") if ShipUtility.Type(shipObj) == ShipType.TorpedoCruiser] # CLT

lambdas["cvl_upgraded"] = lambda: filterUpgraded(getList("cvl")) # 至少一改之后的CVL
lambdas["av_upgraded"] = lambda: filterUpgraded(getList("av")) # 至少一改之后的AV
lambdas["cl_upgraded"] = lambda: filterUpgraded(getList("cl")) # 至少一改之后的CL
lambdas["dd_upgraded"] = lambda: filterUpgraded(getList("dd")) # 至少一改之后的DD
lambdas["de_upgraded"] = lambda: filterUpgraded(getList("de")) # 至少一改之后的DE
lambdas["ss_upgraded"] = lambda: filterUpgraded(getList("ss")) # 至少一改之后的SS
lambdas["ssv_upgraded"] = lambda: filterUpgraded(getList("ssv")) # 至少一改之后的SSV
lambdas["ss_ssv_upgraded"] = lambda: filterUpgraded(getList("ss_ssv")) # 至少一改之后的SS和SSV

lambdas["cl_dlc"] = lambda: filterEquiptable(getList("cl_upgraded"), DLC_CONST_ID) # 可以带大发的CL
lambdas["dd_dlc"] = lambda: filterEquiptable(getList("dd_upgraded"), DLC_CONST_ID) # 可以带大发的DD
lambdas["cl_no_dlc"] = lambda: filterNotEquiptable(getList("cl_upgraded"), DLC_CONST_ID) # 不可以带大发的CL
lambdas["dd_no_dlc"] = lambda: filterNotEquiptable(getList("dd_upgraded"), DLC_CONST_ID) # 不可以带大发的DD
lambdas["cl_kht"] = lambda: filterEquiptable(getList("cl_upgraded"), KHT_CONST_ID) # 可以带甲标的CL

lambdas["cl_expedition"] = lambda: filterFrontProportion(sortByLevelingPreference(getList("cl_no_dlc")), 0.8) # 需要靠远征练级的CL
lambdas["dd_expedition"] = lambda: filterFrontProportion(sortByLevelingPreference(getList("dd_no_dlc")), 0.8) # 需要靠远征练级的DD
lambdas["cvl_expedition"] = lambda: filterFrontProportion(sortByLevelingPreference(getList("cvl_upgraded")), 0.8) # 需要靠远征练级的CVL
lambdas["av_expedition"] = lambda: filterFrontProportion(sortByLevelingPreference(getList("av_upgraded")), 0.8) # 需要靠远征练级的AV
lambdas["de_expedition"] = lambda: filterFrontProportion(sortByLevelingPreference(getList("de_upgraded")), 0.8) # 需要靠远征练级的DE
lambdas["ss_ssv_expedition"] = lambda: filterFrontProportion(sortByLevelingPreference(getList("ss_ssv_upgraded")), 0.8) # 需要靠远征练级的SS和SSV
lambdas["cl_leveling"] = lambdas["cl_expedition"] # 保持与旧版全自动远征配置兼容性 TODO: 以后删掉
lambdas["dd_leveling"] = lambdas["dd_expedition"] # 保持与旧版全自动远征配置兼容性 TODO: 以后删掉
lambdas["av_leveling"] = lambdas["av_expedition"] # 保持与旧版全自动远征配置兼容性 TODO: 以后删掉
lambdas["de_leveling"] = lambdas["de_expedition"] # 保持与旧版全自动远征配置兼容性 TODO: 以后删掉

lambdas["expedition"] = lambda: getList("cl_dlc") + getList("dd_dlc") + getList("cl_expedition") + getList("dd_expedition") + getList("cvl_expedition") + getList("av_expedition") + getList("de_expedition") + getList("ss_ssv_expedition") # 被用作全自动远征的船
lambdas["disposable"] = lambda: sortByIdAsc(filterLevelRange(getList("dd"), 1, 5)) # 狗粮

lambdas["cvl_asc"] = lambda: sortByLevelingPreference(getList("cvl")) # CVL练级排序
lambdas["clt_asc"] = lambda: sortByLevelingPreference(getList("clt")) # CLT练级排序
lambdas["dd_asc"] = lambda: sortByLevelingPreference(getList("dd")) # DD练级排序
lambdas["de_asc"] = lambda: sortByLevelingPreference(getList("de")) # DE练级排序
lambdas["ss_ssv_asc"] = lambda: sortByLevelingPreference(getList("ss_ssv")) # SS和SSV练级排序

lambdas["cv_cvb_desc"] = lambda: sortByForcePreference(getList("cv_cvb")) # CV和CVB强度排序
lambdas["cvl_desc"] = lambda: sortByForcePreference(getList("cvl")) # CVL强度排序
lambdas["cav_desc"] = lambda: sortByForcePreference(getList("cav")) # CAV强度排序
lambdas["ca_desc"] = lambda: sortByForcePreference(getList("ca")) # CA强度排序
lambdas["ca_cav_desc"] = lambda: sortByForcePreference(getList("ca_cav")) # CA和CAV强度排序
lambdas["clt_desc"] = lambda: sortByForcePreference(getList("clt")) # CLT强度排序
lambdas["cl_kht_desc"] = lambda: sortByForcePreference(getList("cl_kht")) # 可以带甲标的CL强度排序
lambdas["dd_desc"] = lambda: sortByForcePreference(getList("dd")) # DD强度排序
lambdas["de_desc"] = lambda: sortByForcePreference(getList("de")) # DE强度排序

# 迭代器
iters = {}
def reset():
	global shipsState
	global lists
	global iters
	shipsState = GameState.Ships()
	lists.clear()
	iters.clear()

def getIter(key):
	global iters
	if key not in iters: # 创建迭代器
		iters[key] = iter(getIds(getList(key)))
	return iters[key]

def getOne(key):
	try:
		return next(getIter(key))
	except StopIteration:
		iters.pop(key)
		return None # 返回-1也行

#===================================================#
#                                                   #
#                        导出                       #
#                                                   #
#===================================================#
# 入渠
def dock_expedition(id): # 用于刷闪修理防止入渠不用于远征的船
	# 每次都查询就太慢了，但这个确实需要更新，但又不需要更新得太频
	from random import random
	if random() <= 0.1:
		reset()
	return id in getIds(getList("expedition"))

# 编成舰队
def OnCandidate(): # 编成计算时会调用
	reset()

def disposable(): # 因为狗粮受拆船影响大，所以需要经常更新候选
	key = "disposable"
	id = getOne(key)
	iterEnd = id is None
	isInvalidId = not iterEnd and ShipUtility.Ship(id) is None # 查找不到船了，就说明解体过一次
	if iterEnd or isInvalidId:
		reset()
		id = getOne(key)
	return id

def grantByLevel_65(ship): # 取自远征38的旗舰等级要求
	global shipsState
	return ShipUtility.Level(ship, shipsState) >= 65

def grantByLevel_50(ship): # 取自远征37、45的旗舰等级要求
	global shipsState
	return ShipUtility.Level(ship, shipsState) >= 50

def grantByLevel_40(ship): # 取自远征B1的旗舰等级要求
	global shipsState
	return ShipUtility.Level(ship, shipsState) >= 40

def grantByLevel_30(ship): # 取自远征41的旗舰等级要求
	global shipsState
	return ShipUtility.Level(ship, shipsState) >= 30

def grantByLevel_20(ship): # 取自远征A2的旗舰等级要求
	global shipsState
	return ShipUtility.Level(ship, shipsState) >= 20

dd_dlc = lambda : getOne("dd_dlc")
cl_dlc = lambda : getOne("cl_dlc")
cl_kht = lambda : getOne("cl_kht")

cvl_expedition = lambda : getOne("cvl_expedition")
av_expedition = lambda : getOne("av_expedition")
cl_expedition = lambda : getOne("cl_expedition")
dd_expedition = lambda : getOne("dd_expedition")
de_expedition = lambda : getOne("de_expedition")
ss_ssv_expedition = lambda : getOne("ss_ssv_expedition")
av_leveling = av_expedition # 保持与旧版全自动远征配置兼容性 TODO: 以后删掉
cl_leveling = cl_expedition # 保持与旧版全自动远征配置兼容性 TODO: 以后删掉
dd_leveling = dd_expedition # 保持与旧版全自动远征配置兼容性 TODO: 以后删掉
de_leveling = de_expedition # 保持与旧版全自动远征配置兼容性 TODO: 以后删掉

cvl_asc = lambda : getOne("cvl_asc")
clt_asc = lambda : getOne("clt_asc")
dd_asc = lambda : getOne("dd_asc")
de_asc = lambda : getOne("de_asc")
ss_ssv_asc = lambda : getOne("ss_ssv_asc")

cv_cvb_desc = lambda : getOne("cv_cvb_desc")
cvl_desc = lambda : getOne("cvl_desc")
cav_desc = lambda : getOne("cav_desc")
ca_desc = lambda : getOne("ca_desc")
ca_cav_desc = lambda : getOne("ca_cav_desc")
clt_desc = lambda : getOne("clt_desc")
cl_kht_desc = lambda : getOne("cl_kht_desc")
dd_desc = lambda : getOne("dd_desc")
de_desc = lambda : getOne("de_desc")
