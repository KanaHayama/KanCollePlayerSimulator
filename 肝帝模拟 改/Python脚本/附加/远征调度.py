# -*- coding: utf-8 -*-

"""
功能：
	调度舰队执行能最快恢复最少资源的远征。

使用方法：
	专用于全自动远征范例配置。
	附加在一个用于控制的执行单元上和数个关联远征执行单元上。

更新记录：
	20200604 - 1.0
		初始版本，随KCPS1.4.1.0发布。
"""

#===================================================#
#                                                   #
#                        导入                       #
#                                                   #
#===================================================#

from KancollePlayerSimulatorKai import *
from KancollePlayerSimulatorKaiCore import *
import re

#===================================================#
#                                                   #
#                        常量                       #
#                                                   #
#===================================================#

NUM_RESOURCE_TYPES = 5
NUM_FLEET = 4

DEFAULT_EXPEDITION_LIST = [ # 每项仅列出了恢复速度最快的3个常规远征（越前越优先）
	["38", "21", "5", ], # 油
	["37", "2", "5", ], # 弹
	["3", "37", "20", ], # 钢
	["6", "45", "B1", ], # 铝
	["B1", "A2", "41", ], # 桶
]
BACKUP_EXPEDITION_LIST = ["3", "2", "B1", "6", ] # 避免冲突，后面接用于替补的远征（越前越优先）
EXPEDITION_LIST = [default + BACKUP_EXPEDITION_LIST for default in DEFAULT_EXPEDITION_LIST]

RESOURCE_SCALE = (1, 1, 1, 1, 100, ) # 资源比较系数

MESSAGE_INITIATE_KIRAKIRA = "开始全自动远征" # 用于启动刷闪配置
MESSAGE_KIRAKIRA = "远征船刷闪完成" # 用于检测刷闪完成
MESSAGE_PREFIX = "Expedition:"
MESSAGE_FORMAT_STRING = MESSAGE_PREFIX + "{}->{}" # 用于启动指定远征配置
MESSAGE_REGEX_STRING = MESSAGE_FORMAT_STRING.replace("{}", r"(\w+)")
MESSAGE_REGEX = re.compile(MESSAGE_REGEX_STRING)

FLEET_ATTRIBUTE_NAME = "Fleet"

MIN_KIRAKIRA_INTERVAL = 60 # 两次刷闪完成之间应至少间隔的秒数

#===================================================#
#                                                   #
#                        变量                       #
#                                                   #
#===================================================#

IS_MASTER = len([w for w in Workflow.ParentGroup if isinstance(w, SimpleExpeditionWorkflow)]) == 0

fleetRecentExpedition = [None for _ in range(NUM_FLEET)] # 用于避免重复选择

lastKiraKiraFinishedTime = None

lastEvent = None

#===================================================#
#                                                   #
#                        工具                       #
#                                                   #
#===================================================#

def sendEvent(message):
	Utility.RaiseEvent(UserEvent(message))

def convertExpeditionNameToId(name):
	'''将远征名转换为游戏内远征ID。'''
	return ExpeditionUtility.GetExpeditionId(name)

def convertExpeditionIdToName(id):
	'''将游戏内远征ID转换为远征名。'''
	return ExpeditionUtility.GetExpeditionName(id)

def getExpeditionId(fleet, fleetsState=None):
	'''返回舰队(1-4)在跑的远征ID，没在跑返回0，舰队未开放返回-1'''
	return FleetUtility.Expedition(fleet, fleetsState) \
		if FleetUtility.Enabled(fleet, fleetsState) else -1

def getExpeditionIds():
	'''4个舰队都返回，而不是只返回2到4'''
	global NUM_FLEET
	fleetsState = GameState.Fleets()
	return [getExpeditionId(fleetIndex + 1, fleetsState) for fleetIndex in range(NUM_FLEET)]

def getNumResource(index, resourcesState=None):
	'''油、弹、钢、铝、高速修复'''
	if 0 <= index and index <= 3:
		vals = BasicUtility.NumBasicMaterial(resourcesState)
		if index == 0:
			return vals.Fuel
		elif index == 1:
			return vals.Bullet
		elif index == 2:
			return vals.Steel
		else:
			assert index == 3
			return vals.Bauxite
	else:
		assert index == 4
		assert getattr(BasicUtility, "NumInstantRepair", None), "请更新KCPS"
		return BasicUtility.NumInstantRepair(resourcesState)

def getLowestResourceIndex():
	global NUM_RESOURCE_TYPES
	global RESOURCE_SCALE
	resourcesState = GameState.Resources()
	resources = [getNumResource(i, resourcesState) * RESOURCE_SCALE[i] for i in range(NUM_RESOURCE_TYPES)]
	minIndex = 0
	minValue = resources[0]
	for i in range(1, NUM_RESOURCE_TYPES):
		if resources[i] < minValue:
			minValue = resources[i]
			minIndex = i
	return minIndex

def selectExpedition(fleet):
	'''选择跑最少资源的远征'''
	global EXPEDITION_LIST
	global fleetRecentExpedition
	resourceIndex = getLowestResourceIndex()
	current = getExpeditionIds()
	fleetIndex = fleet - 1
	for expeditionName in EXPEDITION_LIST[resourceIndex]: # 依次尝试该资源的候选远征，找出不会和当前正在跑的冲突的那一个
		expeditionId = convertExpeditionNameToId(expeditionName) # 这一步其实可以在初始化时做
		if expeditionId not in current[:fleetIndex] \
				and expeditionId not in current[fleetIndex + 1:] \
				and expeditionId not in fleetRecentExpedition[:fleetIndex] \
				and expeditionId not in fleetRecentExpedition[fleetIndex + 1:] \
				: # 其他舰队不在跑这个远征
			return expeditionId
	assert False, "不应该运行到这里"

def notify(fleet):
	'''为舰队指定一个远征'''
	expeditionId = selectExpedition(fleet)
	global MESSAGE_FORMAT_STRING
	message = MESSAGE_FORMAT_STRING.format(fleet, expeditionId)
	sendEvent(message)
	Logger.Debug("安排第{}舰队跑远征{}".format(fleet, convertExpeditionIdToName(expeditionId)))
	global fleetRecentExpedition
	fleetRecentExpedition[fleet - 1] = expeditionId

def isExpeditonReturnedEvent(e):
	return isinstance(e, ExpeditionAboutToReturnedEvent)

def isKirakiraFinishedEvent(e):
	return isinstance(e, UserEvent) and e.Message == MESSAGE_KIRAKIRA

#===================================================#
#                                                   #
#                        导出                       #
#                                                   #
#===================================================#

def OnEvent(e):
	'''新来了一个事件时调用，决定是否触发被附加的执行单元'''
	global IS_MASTER
	# 根据被附加执行单元类型不同，执行不同内容
	if IS_MASTER: # 负责发出指示
		global MESSAGE_KIRAKIRA
		if isExpeditonReturnedEvent(e) or isKirakiraFinishedEvent(e):
			if isExpeditonReturnedEvent(e): 
				Logger.Debug("远征舰队{}归来".format(e.Fleet))
			global lastEvent
			lastEvent = e
			return True # 触发，之后会调用下面的OnProcess
	else: # 负责接收指示
		if isinstance(e, UserEvent): # 先判断一步，避免冗余计算
			global MESSAGE_REGEX
			match = MESSAGE_REGEX.match(e.Message)
			if match:
				fleet = int(match.group(1)) # 消息中的舰队
				expeditionId = int(match.group(2)) # 消息中的远征ID
				workflows = [w for w in Workflow.ParentGroup if isinstance(w, SimpleExpeditionWorkflow)]
				assert len(workflows) == 1, "配置中需有正好1个\"单次发出远征\"执行单元"
				thisFleet = workflows[0].Fleet # 该配置对应的舰队
				thisExpeditionId = workflows[0].Expedition # 该配置对应的远征ID
				if expeditionId == thisExpeditionId: # 消息目标正是本配置
					global FLEET_ATTRIBUTE_NAME
					for w in Workflow.ParentGroup: # 修改这个配置中所有执行单元的舰队属性
						if getattr(w, FLEET_ATTRIBUTE_NAME, None): # 通用（因为起名的时候都叫Fleet，所以可以这么用）
							setattr(w, FLEET_ATTRIBUTE_NAME, fleet) # Fleet都是int型
						if isinstance(w, BasicRefitEquipmentWorkflow): # 基础变更装备执行单元
							for s in w.Ships: # 每一个舰船的装备设置
								s.Fleet = SelectableFleet(fleet) # int 转 enum，这个Fleet不是int型，不转会报错
					expeditionName = convertExpeditionIdToName(expeditionId)
					Logger.Info("配置\"{}\"开始第{}舰队跑远征{}".format(Workflow.ParentGroup.Name, fleet, expeditionName))
					return True  # 触发，之后会调用下面的OnProcess，但OnProfess不是用来处理这个情况的
				elif fleet == thisFleet: # 当前配置和这个远征指令可能出现冲突
					# 关掉使用同舰队的那些远征配置里所有其他执行单元
					for w in Workflow.ParentGroup:
						if w != Workflow:
							w.Enabled = False
	return False

def OnProcess():
	'''触发之后，执行被附加的执行单元自身功能之前调用'''
	global IS_MASTER
	if not IS_MASTER:
		return # 消息接收者不需要在这一步做任何事
	
	global lastEvent
	if lastEvent and isinstance(lastEvent, ExpeditionAboutToReturnedEvent): # 某个舰队回来时
		notify(lastEvent.Fleet)
		Logger.Debug("处理了舰队{}的远征归来事件".format(lastEvent.Fleet))
	else: # 发出所有舰队（刷闪完成或者手动点击“立即触发“时）
		causedByKirakiraFinished = lastEvent and isKirakiraFinishedEvent(lastEvent)
		if causedByKirakiraFinished：
			global lastKiraKiraFinishedTime
			now = datetime.now()
			if lastKiraKiraFinishedTime # 检查两次刷闪完成事件间的时间，过少说明一次都没出击
				global MIN_KIRAKIRA_INTERVAL
				if (now - lastKiraKiraFinishedTime).total_seconds() <= MIN_KIRAKIRA_INTERVAL:
					raise Exception("账号中的舰船不满足远征的要求，请检查后再试")
					# 当然，这里也可以找出出错的远征然后换个远征跑，但那只是在掩盖问题
			lastKiraKiraFinishedTime = now
		global NUM_FLEET
		fleetsState = GameState.Fleets()
		for fleetIndex in range(1, NUM_FLEET): # 安排发出所有远征队
			fleet = fleetIndex + 1
			if FleetUtility.Enabled(fleet, fleetsState):
				notify(fleet)
		if not causedByKirakiraFinished:# 刚被通知刷完闪就不要再去刷了，避免死循环
			global MESSAGE_INITIATE_KIRAKIRA
			sendEvent(MESSAGE_INITIATE_KIRAKIRA) # 去刷闪
	lastEvent = None # 复位
