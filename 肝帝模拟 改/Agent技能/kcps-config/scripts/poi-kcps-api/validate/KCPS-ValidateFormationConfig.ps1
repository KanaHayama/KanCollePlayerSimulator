#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Path
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\KCPS-Common.ps1"

$resolved = Resolve-Path -LiteralPath $Path
if ((Get-Item -LiteralPath $resolved).PSIsContainer) {
    throw 'Validate one formation .conf.json file at a time.'
}

$config = Read-KcpsJson -Path ([string]$resolved)
$reports = @()
$totalProblems = 0

foreach ($group in Get-KcpsGroups -Config $config) {
    $problems = @()
    $list = @($group['List'])
    $name = [string]$group['Name']

    if ($list.Count -eq 0) {
        $problems += '配置不包含执行单元。'
    } elseif ([string]$list[0]['Name'] -ne '说明') {
        $problems += '说明执行单元必须位于配置最前面。'
    }

    $accepts = @($list | Where-Object { Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicAcceptQuestWorkflow' })
    $organizers = @($list | Where-Object { Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicOrganizeFleetWorkflow' })
    $forbidden = @($list | Where-Object {
        (Test-KcpsWorkflowType -Workflow $_ -TypeName 'RelationalExerciseWorkflow') -or
        (Test-KcpsWorkflowType -Workflow $_ -TypeName 'RelationalSortieWorkflow') -or
        (Test-KcpsWorkflowType -Workflow $_ -TypeName 'SimpleSortieWorkflow') -or
        (Test-KcpsWorkflowType -Workflow $_ -TypeName 'RelationalExpeditionWorkflow') -or
        (Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicRefitEquipmentWorkflow') -or
        (Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicSupplyFleetWorkflow') -or
        (Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicDockingWorkflow')
    })

    if ($accepts.Count -ne 1) {
        $problems += "每个编成任务配置必须且只能有一个 BasicAcceptQuestWorkflow，当前为 $($accepts.Count)。"
    }
    if ($organizers.Count -ne 1) {
        $problems += "每个编成任务配置必须且只能有一个 BasicOrganizeFleetWorkflow，当前为 $($organizers.Count)。"
    }
    if ($forbidden.Count -gt 0) {
        $problems += "编成任务包含不应出现的演习、出击、远征、改装、补给或入渠 workflow：$(@($forbidden.Name) -join ', ')。"
    }

    foreach ($requiredName in @('说明', '接任务', '编成')) {
        if (@($list | Where-Object { [string]$_['Name'] -eq $requiredName }).Count -ne 1) {
            $problems += "必须且只能有一个名为 '$requiredName' 的执行单元。"
        }
    }
    if ($list.Count -ne 3) {
        $problems += "纯编成任务应只包含说明、接任务、编成三个执行单元，当前为 $($list.Count)。"
    }

    foreach ($workflow in $list) {
        if ([bool]$workflow['EnableOnLoad']) {
            $problems += "执行单元 '$($workflow['Name'])' 不得载入时启用。"
        }
        if ([bool]$workflow['TriggerOnEnabled']) {
            $problems += "执行单元 '$($workflow['Name'])' 不得启用时立即触发。"
        }
    }

    foreach ($accept in $accepts) {
        $quests = @($accept['Quests'])
        if ($quests.Count -ne 1) {
            $problems += "接任务执行单元应包含一个精确任务，当前为 $($quests.Count)。"
        }
        foreach ($quest in $quests) {
            if ([int]$quest['SelectMethod'] -ne 0) {
                $problems += '接任务必须按精确任务 ID 选择。'
            }
            if (-not [bool]$quest['FailIfNotExist']) {
                $problems += "接任务 ID $($quest['SelectValue']) 必须设置任务不存在算失败。"
            }
            if ([bool]$quest['FailIfAccepted']) {
                $problems += "接任务 ID $($quest['SelectValue']) 已接受时不应算失败。"
            }
        }
    }

    foreach ($organizer in $organizers) {
        $positions = @($organizer['Positions'])
        if ($positions.Count -lt 1 -or $positions.Count -gt 6) {
            $problems += "编成位置数必须为 1..6，当前为 $($positions.Count)。"
        }
        $positionNumber = 0
        foreach ($position in $positions) {
            $positionNumber++
            $selections = @($position['Selections'])
            $args = @($position['SelectShipArgs'])
            if ($selections.Count -eq 0 -or $args.Count -eq 0) {
                $problems += "编成位置 $positionNumber 缺少候选船。"
                continue
            }
            $selectionIds = @($selections | ForEach-Object { [string]$_['Value'] } | Sort-Object -Unique)
            $argIds = @($args | ForEach-Object { [string]$_['Value'] } | Sort-Object -Unique)
            if (($selectionIds -join ',') -ne ($argIds -join ',')) {
                $problems += "编成位置 $positionNumber 的 Selections 与 SelectShipArgs 候选不一致。"
            }
        }
    }

    $totalProblems += $problems.Count
    $reports += [ordered]@{
        Config = $name
        AcceptQuestWorkflowCount = $accepts.Count
        OrganizeWorkflowCount = $organizers.Count
        ForbiddenWorkflowCount = $forbidden.Count
        ProblemCount = $problems.Count
        Problems = @($problems)
    }
}

[ordered]@{
    Path = [string]$resolved
    ConfigCount = @($reports).Count
    ProblemCount = $totalProblems
    Configs = @($reports)
} | ConvertTo-Json -Depth 10

