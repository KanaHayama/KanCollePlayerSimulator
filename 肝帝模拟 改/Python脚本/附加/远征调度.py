# -*- coding: utf-8 -*-

"""
功能：
	调度舰队执行能最高效增加资源的远征。

使用方法：
	专用于全自动远征范例配置。
	附加在一个用于控制的执行单元上和数个关联远征执行单元上。

更新记录：
	20210920 - 2.3
		根据更详细的数据源调整远征收益表
	20201127 - 2.2
		调整参数
	20201115 - 2.1
		动态降低短远征的重要性。
	20201113 - 2.0
		根据多种资源量动态选取最优远征。
	20200624 - 1.2
		避免刷闪完成后冗余的发出远征指令。
	20200621 - 1.1
		资源相近时避免反复切换返回的最低资源种类。
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
from datetime import datetime
import re

#===================================================#
#                                                   #
#                        常量                       #
#                                                   #
#===================================================#

NUM_RESOURCE_TYPES = 5
NUM_FLEET = 4

EXPEDITION_MINUTE = {
	"2": 30,
	"3": 20,
	"5": 90,
	"6": 40,
	"A2": 55,
	
	"B1": 35,
	
	"21": 140,
	
	"41": 60,
	"45": 200,
	
	"37": 165,
	"38": 175,
} # 远征需要的分钟数。此处的远征需要与远征子配置对应。

EXPEDITION_GAIN = {
	"2":  (-30., 150.,  30.,   0.,  .5, ), # TODO：获得修复桶概率是随便填的，不知道去哪里能查证
	"3":  ( 31.,  36.,  40.,   0., 0. , ),
	"5":  (272., 300.,  20.,  20., 0. , ),
	"6":  (-18., -12.,   0.,  80., 0. , ),
	"A2": ( 85.,  52.,   0.,  10.,  .5, ), # TODO：获得修复桶概率是随便填的，不知道去哪里能查证
	
	"B1": (-45., -15.,  20.,  30., 1. , ),
	
	"21": (412., 351.,   0.,   0., 0. , ),
	
	"41": (135., -15.,   0.,  20., 1. , ),
	"45": ( 41., -26.,   0., 220., 0. , ),
	
	"37": (-80., 480., 270.,   0., 0. , ),
	"38": (558., -72., 200.,   0., 0. , ),
} # 每次远征获得资源量。此处使用wiki上的理论收益（大成功）。

RESOURCE_MAXIMUM = (350000, 350000, 350000, 350000, 3000, ) # 资源最大值。用于在接近最大值时降低该资源重要性。

MAX_EXPEDITION_MINUTE = max(EXPEDITION_MINUTE.values()) # 耗时最长的远征的时长

UPDATE_INTERVAL_SECOND = 20 * 60 * 60 # 返回的资源量稳定不变动的秒数。且用作固定统计时间区间。

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

fleetFailedToSelectShip = [False for _ in range(NUM_FLEET)] # 记录编成失败导致没发出去远征的舰队

lastKiraKiraFinishedTime = None

lastEvent = None

lastUpdateTime = None

lastResources = None

expeditionCount = 0 # 用于计数固定期间内发远征次数

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

def getResourceScales(): # 结果实际是常数
	'''资源数值放大倍数'''
	global RESOURCE_MAXIMUM
	global NUM_RESOURCE_TYPES
	m = float(max(RESOURCE_MAXIMUM))
	scales = [m / RESOURCE_MAXIMUM[i] for i in range(NUM_RESOURCE_TYPES)]
	return scales

def getResources():
	'''获取当前所有资源量'''
	global NUM_RESOURCE_TYPES
	global UPDATE_INTERVAL_SECOND
	global lastUpdateTime
	global lastResources
	global expeditionCount
	now = datetime.now()
	if lastUpdateTime and (now - lastUpdateTime).total_seconds() <= UPDATE_INTERVAL_SECOND:
		return lastResources # 使结果在一定时间范围内保持不变
	resourcesState = GameState.Resources()
	resources = [getNumResource(i, resourcesState) for i in range(NUM_RESOURCE_TYPES)]
	lastUpdateTime = now
	lastResources = resources
	expeditionCount = 0
	return resources

def getResourceWeights(resources, scales):
	'''获取各项资源的权重。区间为0到1，和为1。量少的资源权重高。'''
	global NUM_RESOURCE_TYPES
	scaled = [r * s for r, s in zip(resources, scales)] # 按比例缩放后的资源量
	m = float(max(scaled))
	inf = float("inf")
	def calcWeight(i): # 这个函数决定了如何给资源设定权重。有特殊需求的用户可自定义。
		global RESOURCE_MAXIMUM
		f1 = m / scaled[i] if scaled[i] > 0 else inf # 优先分给少的资源大权重
		resMax = RESOURCE_MAXIMUM[i] + 1. / scales[i] # 比真正的最大值稍大一点点，为了最终权重不降为0
		f2 = 1. - (resources[i] / resMax) ** 10 # 接近最大值则降低效果
		weight = f1 * f2
		return weight
	weights = [calcWeight(i) for i in range(NUM_RESOURCE_TYPES)]
	s = sum(weights)
	norm = None
	if s == inf:
		num = weights.count(inf)
		norm = [1. / num if w == inf else 0. for w in weights]
	elif s == 0:
		norm = [1. / NUM_RESOURCE_TYPES for _ in weights]
	else:
		norm = [w / s for w in weights]
	return norm

def getExpeditionUnitGain(expeditionName, resourceIndex):
	'''单位时间能获得的某项资源量'''
	global EXPEDITION_GAIN
	global EXPEDITION_MINUTE
	return EXPEDITION_GAIN[expeditionName][resourceIndex] / EXPEDITION_MINUTE[expeditionName]

def getExpeditionCountSaftyCoef(expeditionName): # 有特殊需求的用户可自定义。
	'''远征次数安全系数。区间为0到1。用于在远征次数过多时降低短远征的重要性。'''
	global EXPEDITION_MINUTE
	global MAX_EXPEDITION_MINUTE
	global expeditionCount
	timeF = float(EXPEDITION_MINUTE[expeditionName]) / MAX_EXPEDITION_MINUTE # 远征用时
	refMaxExpeditionCount = 80 # 越小越容易调整到长时间远征。
	countF = float(expeditionCount) / refMaxExpeditionCount
	coef = 1 - (1 - timeF) * (countF ** 2) # 最后的那个指数越大，越不容易调整到长时间远征。
	return coef

def allExpeditions(): # 结果实际是常数
	'''返回所有支持的远征'''
	global EXPEDITION_MINUTE
	expeditions = EXPEDITION_MINUTE.keys()
	return expeditions

def sortExpeditions():
	'''根据当前资源状况排序支持的远征'''
	resources = getResources()
	scales = getResourceScales()
	weights = getResourceWeights(resources, scales)
	def calcWeight(expeditionName): # 有特殊需求的用户可自定义。
		global NUM_RESOURCE_TYPES
		global RESOURCE_SCALE
		expeditionCountSaftyCoef = getExpeditionCountSaftyCoef(expeditionName)
		sum = 0. # 为了条理清晰一点，这里没有使用sum()
		for i in range(NUM_RESOURCE_TYPES):
			unitGain = getExpeditionUnitGain(expeditionName, i)
			sum += weights[i] * (scales[i] * unitGain) * expeditionCountSaftyCoef
		return sum
	expeditions = allExpeditions()
	expeditions.sort(key=calcWeight, reverse=True)
	return expeditions

def selectExpedition(fleet):
	'''为舰队选一个远征'''
	global EXPEDITION_LIST
	global fleetRecentExpedition
	current = getExpeditionIds()
	fleetIndex = fleet - 1
	expeditions = sortExpeditions()
	Logger.Debug("当前最合适远征依次为：{}".format(" ".join(expeditions)))
	for expeditionName in expeditions: # 依次尝试当前最合适的远征，找出不会和当前正在跑的冲突的那一个
		expeditionId = convertExpeditionNameToId(expeditionName) # 这一步其实可以在初始化时做
		if expeditionId not in current[:fleetIndex] \
				and expeditionId not in current[fleetIndex + 1:] \
				and expeditionId not in fleetRecentExpedition[:fleetIndex] \
				and expeditionId not in fleetRecentExpedition[fleetIndex + 1:] \
				: # 其他舰队不在跑这个远征
			return expeditionId
	assert False, "不应该运行到这里"

def notify(fleet):
	'''安排舰队去跑远征。实际是用消息通知各个远征子配置。'''
	expeditionId = selectExpedition(fleet)
	global MESSAGE_FORMAT_STRING
	message = MESSAGE_FORMAT_STRING.format(fleet, expeditionId)
	sendEvent(message)
	Logger.Debug("安排第{}舰队跑远征{}".format(fleet, convertExpeditionIdToName(expeditionId)))
	global fleetRecentExpedition
	fleetRecentExpedition[fleet - 1] = expeditionId
	global expeditionCount
	expeditionCount += 1

def isExpeditonReturnedEvent(e):
	return isinstance(e, ExpeditionAboutToReturnedEvent)

def isKirakiraFinishedEvent(e):
	return isinstance(e, UserEvent) and e.Message == MESSAGE_KIRAKIRA

def isExpeditionFleetOrganizeFailedEvent(e):
	return isinstance(e, OrganizeChangeFailedEvent) and 2 <= e.Fleet and e.Fleet <= 4

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
		if isExpeditonReturnedEvent(e) or isKirakiraFinishedEvent(e):
			if isExpeditonReturnedEvent(e): 
				Logger.Debug("远征舰队{}归来".format(e.Fleet))
			global lastEvent
			lastEvent = e
			return True # 触发，之后会调用下面的OnProcess
		if isExpeditionFleetOrganizeFailedEvent(e): # 监控远征舰队换编成失败事件，此时该舰队不能正常派出远征
			global fleetFailedToSelectShip
			fleetFailedToSelectShip[e.Fleet - 1] = True
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
		causedByKirakiraFinished = lastEvent and isKirakiraFinishedEvent(lastEvent) # 进入这里的原因
		# 步骤1: 检查
		if causedByKirakiraFinished:
			global lastKiraKiraFinishedTime
			now = datetime.now()
			if lastKiraKiraFinishedTime: # 检查两次刷闪完成事件间的时间，过少说明一次都没出击
				global MIN_KIRAKIRA_INTERVAL
				if (now - lastKiraKiraFinishedTime).total_seconds() <= MIN_KIRAKIRA_INTERVAL:
					lastKiraKiraFinishedTime = None
					raise Exception("账号中的舰船不满足远征的要求，请检查后再试")
					# 当然，这里也可以找出出错的远征然后换个远征跑，但那只是在掩盖问题
			lastKiraKiraFinishedTime = now
		# 步骤2: 安排发远征
		global NUM_FLEET
		global fleetFailedToSelectShip
		fleetsState = GameState.Fleets()
		for fleetIndex in range(1, NUM_FLEET): # 安排发出所有远征队
			fleet = fleetIndex + 1
			if FleetUtility.Enabled(fleet, fleetsState) and (\
				not causedByKirakiraFinished \
				or fleetFailedToSelectShip[fleetIndex] \
			):
				notify(fleet)
				fleetFailedToSelectShip[fleetIndex] = False
		# 步骤3： 安排刷闪
		if not causedByKirakiraFinished:# 刚被通知刷完闪就不要再去刷了，避免死循环
			global MESSAGE_INITIATE_KIRAKIRA
			sendEvent(MESSAGE_INITIATE_KIRAKIRA) # 去刷闪
	lastEvent = None # 复位
