#requires -Version 7.0

function Get-KcpsFarmingProblems {
    param(
        [System.Collections.IDictionary]$RouteSpec,
        [System.Collections.IDictionary]$Controller,
        [System.Collections.IDictionary]$Sortie,
        [System.Collections.IDictionary]$Maps
    )
    if ($null -eq $RouteSpec -or $null -eq $RouteSpec['StageDesign'] -or
        [string]$RouteSpec['StageDesign']['Phase'] -ne 'Farming') { return }
    $stage = $RouteSpec['StageDesign']
    $targets = @($stage['DropTargets'] | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($targets.Count -eq 0) { '捞船规格缺少目标船名。' }
    $expected = '^(' + (($targets | ForEach-Object { [regex]::Escape([string]$_) }) -join '|') + ')$'
    if ($null -eq $Controller -or -not [bool]$Controller['StopIfGetShipFlag'] -or
        [string]$Controller['StopIfGetShipValueShipName'] -cne $expected) {
        '捞船必须启用原生获得指定舰船停止，使用转义并锚定的目标船名或关系。'
    }
    if ($null -eq $Sortie) { '捞船配置缺少出击执行单元。'; return }
    if ([bool]$Sortie['MapHpInRangeFlag']) { '通关后捞船不能继承磨血或斩杀的海域量值门禁。' }
    $requiredMaps = @($stage['PostClearRequiredMaps'])
    if ($requiredMaps.Count -eq 0) { '通关后捞船必须声明需要确认通关的地图。' }
    foreach ($id in $requiredMaps) {
        if ($null -eq $Maps -or -not $Maps.Contains([string]$id) -or
            [int]$Maps[[string]$id]['api_cleared'] -ne 1) {
            "地图 $id 未确认通关，不能应用通关后敌编成或贴条规则。"
        }
    }
    if ($null -eq $Controller) { return }
    # 次数和容量是兜底，不允许残留攻略任务的停止开关。
    $allowed = @('StopIfGetShipFlag', 'StopIfLoopCountLargerOrEqualThanFlag',
        'StopIfShipVacancyLessOrEqualThanFlag', 'StopIfEquipmentVacancyLessOrEqualThanFlag')
    foreach ($key in $Controller.Keys) {
        if ($key -match '^StopIf.*Flag$' -and [bool]$Controller[$key] -and $key -notin $allowed) {
            "捞船总控残留任务停止条件：$key。"
        }
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Controller['Script'])) {
        '原生捞船停止配置不能继承攻略总控脚本；额外脚本需单独审核后扩展规则。'
    }
    if ([string]$stage['AutomationMode'] -eq 'MultiLoop') {
        if (-not [bool]$Controller['StopIfLoopCountLargerOrEqualThanFlag'] -or
            [int]$Controller['StopIfLoopCountLargerOrEqualThanValue'] -le 1) {
            '全自动捞船应有多轮安全上限，不能以一轮代替获得目标舰船判定。'
        }

    }
}
