# -*- coding: utf-8 -*-

# 查看模块里都有什么东西能在python脚本里用

import KancollePlayerSimulatorKaiCore
import KancollePlayerSimulatorKai

def print_all(module_):
	modulelist = dir(module_)
	length = len(modulelist)
	for i in range(0,length,1):
		print getattr(module_,modulelist[i])

print_all(KancollePlayerSimulatorKaiCore)
print_all(KancollePlayerSimulatorKai)