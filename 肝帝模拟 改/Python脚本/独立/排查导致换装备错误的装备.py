# -*- coding:utf-8 -*-

"""
功能：
	装备或者舰船外部数据出错或者没更新的话会导致换装备出错
	使用本脚本可以列出每页都有什么装备，对照一下实际游戏画面中显示的装备，找到从哪一项开始对不上，就可以知道多了或少了或排序错了哪些装备了
	使用前需要设置出问题的 【舰船ID】 以及 【装备槽】

使用方法：
	附加在需要的执行单元上（如基础编成舰队）
	在填写函数的地方填写需要的函数名（见范例配置中的示例）

更新记录：
	20221118 - 1.3
		修改1.5.0.0中变更了的函数名
	20221118 - 1.2
		修改1.4.2.0中变更了的函数名
	20191122 - 1.1
		修复了没计入陆航的bug
	20190807 - 1.0
		初始版本
"""


from KancollePlayerSimulatorKaiCore import * 

# 运行前设置一下
shipId = -1 # 这里设置出错了的舰船ID，你可以使用编成执行单元的导入功能找到这个ID
slot = EquipmentSlot.Slot1 # 这里设置出错了的装备槽枚举值，扩展装备槽为[EquipmentSlot.SlotEx]

# 判断用户有没有无脑操作
if shipId <= 0:
	raise Exception("你还没设置就运行了这个脚本，请认真阅读脚本开头的使用说明！！！")

# 找到这艘船的信息
shipObj = ShipUtility.Ship(shipId)
if shipObj is None:
	raise Exception("没有找到ID为%d的船" % shipId)
shipReadableName = ShipUtility.HumanReadable(shipObj)
print("你在Python代码中设定的换装备出错的船为%s" % shipReadableName)

# 找到这艘船的常量信息
shipConstObj = ShipConstUtility.ShipConst(shipObj)

# 判断装备槽是否可用
slotAvailable = ShipUtility.ExtraSlotAvailable(shipObj) if slot == EquipmentSlot.SlotEx else ShipConstUtility.SlotCount(shipConstObj) >= int(slot)
if not slotAvailable:
	raise Exception("%s的给定装备槽没有开放" % shipReadableName)

# 提示
print("整个过程需要一些时间，请耐心等待")

# 找到这艘船这个装备槽所有能使用的装备常量
availableEquipmentConstIds = ShipConstUtility.AllowedEquipmentConsts(shipConstObj, slot)

# 找到所有的装备
equipmentObjs = EquipmentUtility.All()

# 找到该船上已经有了的所有装备
equipedEquipmentIds = ShipUtility.AllEquipments(shipObj)

# 找到放在基地航空队中的装备
landbasedEquipmentIds = [LandBasedAirCorpsUtility.SquadronAirplaneEquipmentId(s) for c in LandBasedAirCorpsUtility.AllCorps() for s in LandBasedAirCorpsUtility.AllSquadrons(c) ]

# 找到这艘船这个装备槽所有能使用的装备
availableEquipmentObjs = [equipmentObj for equipmentObj in equipmentObjs if \
			EquipmentUtility.ConstId(equipmentObj) in availableEquipmentConstIds \
			and \
			EquipmentUtility.Id(equipmentObj) not in equipedEquipmentIds \
			and \
			EquipmentUtility.Id(equipmentObj) not in landbasedEquipmentIds \
		]

# 排序
sortedAvailableEquipmentObjs = EquipmentUtility.Sort(availableEquipmentObjs)

# 分成空闲装备和非空闲装备
inUseEquipmentObjs = [equipmentObj for equipmentObj in sortedAvailableEquipmentObjs if EquipmentUtility.Ship(equipmentObj) != 0]
notInUseEquipmentObjs = [equipmentObj for equipmentObj in sortedAvailableEquipmentObjs if EquipmentUtility.Ship(equipmentObj) == 0]

# 定义打印函数
PAGE_CAPACITY = 10
from collections import OrderedDict
def printPages(equipmentObjs):
	totalEquipments = len(equipmentObjs)
	totalPages = totalEquipments / PAGE_CAPACITY + (1 if totalEquipments % PAGE_CAPACITY != 0 else 0)
	print("一共有%d页" % totalPages)
	for pageIndex in range(totalPages):
		
		pageEquipmentObjs = equipmentObjs[pageIndex * PAGE_CAPACITY : (pageIndex + 1) * PAGE_CAPACITY]
		d = OrderedDict()
		for equipmentObj in pageEquipmentObjs:
			equipmentName = EquipmentConstUtility.Name(EquipmentConstUtility.EquipmentConst(equipmentObj))
			if equipmentName in d.keys():
				d[equipmentName] = d[equipmentName] + 1
			else:
				d[equipmentName] = 1
		l = ["%s 有 %d 个" % (k, v) for k, v in d.items()]
		print("第%d页：%s" % (pageIndex + 1, "， ".join(l)))

# 打印
print("") # 因为是Python2，所以不支持print()
print("【以下是没在使用的装备的列表】")
printPages(notInUseEquipmentObjs)

print("")
print("【以下是在使用的装备的列表】")
printPages(inUseEquipmentObjs)

# 提示
print("")
print("如果你看到的内容有缺损，请调大控制台输出窗口接受的字符数后再次运行")
print("现在，你可以去比较一下上面的内容和你看到的是否一致了")
print("如果不一致请从前往后找到以上列表多了或者少了或者排序错了的项目，然后在Github Issue上报告给我，请先搜索有没有人报告类似的问题，报告时请带上舰船、装备槽、多出或者少出的项目、以及上面的打印信息")

'''
更新记录：
2019/08/07-初始版本
2019/11/22-修复没排除基地航空队中装备的Bug
'''