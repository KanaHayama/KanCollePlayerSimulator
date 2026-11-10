#requires -Version 7.0
param([string]$Path, [string]$SnapshotPath)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../KCPS-Common.ps1"
$script:checks = 0
function Assert($ok, $label) {
    if (-not $ok) { throw $label }
    $script:checks++
}
function Clone($value) {
    ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $value -Depth 100) -AsHashtable -NoEnumerate
}
# 单独提取载入格式校验，避免为纯离线格式用例读取账号快照。
$validatorAst = [System.Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot/KCPS-ValidateConfig.ps1", [ref]$null, [ref]$null)
$typeCheckAst = $validatorAst.Find({ param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-KcpsWorkflowTypeLoadProblems'
}, $true)
if (-not $typeCheckAst) { throw '缺少执行单元 Type 载入格式校验' }
. ([scriptblock]::Create($typeCheckAst.Extent.Text))
foreach ($typeName in @('MemoWorkflow', 'SimpleSortieWorkflow', 'RelationalSortieWorkflow', 'SimpleRaiseUserEventWorkflow')) {
    foreach ($version in @('1.4.3.0', '1.4.4.0', '2.9.0.0', '99.0.0.0', '1.2', '1.2.3')) {
        $workflow = @{ Name = '合成执行单元'; Type = "KancollePlayerSimulatorKai.$typeName, KancollePlayerSimulatorKai, Version=$version, Culture=neutral, PublicKeyToken=null" }
        $beforeType = $workflow.Type
        Assert (@(Get-KcpsWorkflowTypeLoadProblems @($workflow)).Count -eq 0) "有效完整 Type 被误报：$typeName $version"
        Assert ($workflow.Type -ceq $beforeType) 'Type 校验不应重写版本'
    }
}
foreach ($case in @(
    @{ Name = '缺失'; Type = $null },
    @{ Name = '空字符串'; Type = '' },
    @{ Name = '非字符串'; Type = 12 },
    @{ Name = '短类型'; Type = 'KancollePlayerSimulatorKai.MemoWorkflow, KancollePlayerSimulatorKai' },
    @{ Name = '版本缺逗号'; Type = 'KancollePlayerSimulatorKai.MemoWorkflow, KancollePlayerSimulatorKai, Version=1.2.3.4' },
    @{ Name = '版本字段大小写'; Type = 'KancollePlayerSimulatorKai.MemoWorkflow, KancollePlayerSimulatorKai, version=1.2.3.4, Culture=neutral' },
    @{ Name = '版本字段空格'; Type = 'KancollePlayerSimulatorKai.MemoWorkflow, KancollePlayerSimulatorKai, Version =1.2.3.4, Culture=neutral' },
    @{ Name = '版本字段负数'; Type = 'KancollePlayerSimulatorKai.MemoWorkflow, KancollePlayerSimulatorKai, Version=-1.2.3.4, Culture=neutral' },
    @{ Name = '单段版本'; Type = 'KancollePlayerSimulatorKai.MemoWorkflow, KancollePlayerSimulatorKai, Version=1, Culture=neutral' },
    @{ Name = '空版本段'; Type = 'KancollePlayerSimulatorKai.MemoWorkflow, KancollePlayerSimulatorKai, Version=1..2, Culture=neutral' },
    @{ Name = '过多版本段'; Type = 'KancollePlayerSimulatorKai.MemoWorkflow, KancollePlayerSimulatorKai, Version=1.2.3.4.5, Culture=neutral' },
    @{ Name = '版本整数溢出'; Type = 'KancollePlayerSimulatorKai.MemoWorkflow, KancollePlayerSimulatorKai, Version=2147483648.2, Culture=neutral' }
)) {
    $problems = @(Get-KcpsWorkflowTypeLoadProblems @($case))
    Assert ($problems.Count -eq 1 -and $problems[0].Key -eq 'Type') "漏检 Type $($case.Name)"
}
$missingType = @{ Name = '没有类型字段' }
Assert (@(Get-KcpsWorkflowTypeLoadProblems @($missingType)).Count -eq 1) '漏检缺失 Type 字段'

$id = 'e6b8c457-e362-44eb-8449-f0244b416056'
$good = @{Guid=$id;Enabled=$true;IgnoreTriggerFailure=$false}
$sortie = @{Type='KancollePlayerSimulatorKai.SimpleSortieWorkflow, KancollePlayerSimulatorKai';Guid=$id;Name='出击'}
$controller = @{Type='KancollePlayerSimulatorKai.RelationalSortieWorkflow, KancollePlayerSimulatorKai';Name='总控';SortieWorkflow=$good}
function Problems($reference, $targets=@($sortie)) {
    $controller.SortieWorkflow = $reference
    @(Get-KcpsSortieWorkflowReferenceProblems -Workflows (@($controller) + $targets))
}
Assert (@(Problems $good).Count -eq 0) '有效关联对象被误报'
Assert (@(Problems @{Guid=$id}).Count -eq 0) '原生缺省布尔值被误报'
foreach ($case in @(
    @{Name='裸GUID';Value=$id},
    @{Name='单元素数组';Value=@($good)},
    @{Name='空数组';Value=@()},
    @{Name='空值';Value=$null},
    @{Name='数字';Value=1},
    @{Name='缺少GUID';Value=@{}},
    @{Name='非法GUID';Value=@{Guid='not-a-guid'}},
    @{Name='空GUID';Value=@{Guid=[guid]::Empty.ToString()}},
    @{Name='非字符串GUID';Value=@{Guid=17}},
    @{Name='启用值为字符串';Value=@{Guid=$id;Enabled='true'}},
    @{Name='启用值为空';Value=@{Guid=$id;Enabled=$null}},
    @{Name='忽略失败值为字符串';Value=@{Guid=$id;IgnoreTriggerFailure='false'}},
    @{Name='禁用出击关联';Value=@{Guid=$id;Enabled=$false}}
)) {
    Assert (@(Problems $case.Value).Count -gt 0) "漏检$($case.Name)"
}
$controller.Remove('SortieWorkflow')
Assert (@(Get-KcpsSortieWorkflowReferenceProblems @($controller,$sortie)).Count -gt 0) '漏检缺失的单引用'
Assert (@(Problems $good @()).Count -gt 0) '漏检跨配置或悬空关联'
Assert (@(Problems $good @($sortie,$sortie)).Count -gt 0) '漏检非唯一关联'
$wrongType = Clone $sortie
$wrongType.Type = 'KancollePlayerSimulatorKai.MemoWorkflow, KancollePlayerSimulatorKai'
Assert (@(Problems $good @($wrongType)).Count -gt 0) '漏检指向备注的出击关联'
Assert (@(Get-KcpsSortieWorkflowReferenceProblems @($sortie)).Count -eq 0) '误报不含关联出击的独立执行单元'

if ($Path -or $SnapshotPath) {
    if (-not $Path -or -not $SnapshotPath) { throw '正式入口回归需要同时指定Path和SnapshotPath' }
    $groups = @(Get-KcpsGroups (Read-KcpsJson $Path))
    foreach ($group in $groups) {
        Assert (@(Get-KcpsSortieWorkflowReferenceProblems $group.List).Count -eq 0) "$($group.Name)关联格式错误"
    }
    $negative = Clone $groups
    $mutatedCount = 0
    foreach ($group in $negative) {
        foreach ($ctl in @($group.List | Where-Object { Test-KcpsWorkflowType $_ 'RelationalSortieWorkflow' })) {
            # 保留正确GUID，重现载入时丢失总控的错误。
            $ctl.SortieWorkflow = $ctl.SortieWorkflow.Guid
            $mutatedCount++
        }
    }
    Assert ($mutatedCount -gt 0) '测试配置没有总控'
    $testPath = Join-Path ([IO.Path]::GetTempPath()) ("kcps-reference-" + [guid]::NewGuid().ToString('N') + '.conf.json')
    try {
        ConvertTo-Json -InputObject $negative -Depth 100 | Set-Content -LiteralPath $testPath -Encoding utf8
        $general = (& "$PSScriptRoot/KCPS-ValidateConfig.ps1" -Path $testPath -SnapshotPath $SnapshotPath | Out-String) | ConvertFrom-Json -AsHashtable
        $event = (& "$PSScriptRoot/KCPS-ValidateEventSortieConfig.ps1" -Path $testPath -SnapshotPath $SnapshotPath -NoThrow | Out-String) | ConvertFrom-Json -AsHashtable
        Assert ($general.ProblemCount -ge $mutatedCount) '通用入口未拒绝错误单引用'
        $shapeErrors = @($general.Groups | ForEach-Object { $_.WorkflowRefShapeProblems } | Where-Object { $_.Key -eq 'SortieWorkflow' -and $_.Problem -match '关联对象' })
        Assert ($shapeErrors.Count -eq $mutatedCount) '通用入口漏检有效GUID的错误引用格式'
        Assert (@($event | Where-Object { -not $_.Valid -and @($_.Problems | Where-Object { $_ -match 'SortieWorkflow.*关联对象' }).Count -gt 0 }).Count -eq $groups.Count) '活动入口漏检总控载入失败'
        $failed = $false
        try {
            $null = & "$PSScriptRoot/KCPS-ValidateConfig.ps1" -Path $testPath -SnapshotPath $SnapshotPath -FailOnProblems
        } catch { $failed = $true }
        Assert $failed 'FailOnProblems没有阻止交付'

        $badTypes = Clone $groups
        $typeMutationCount = 0
        foreach ($group in $badTypes) {
            foreach ($workflow in @($group.List)) {
                # 所有执行单元都经过原生版本迁移入口，不仅是通知或总控。
                $workflow.Type = [regex]::Replace([string]$workflow.Type, ', Version=.*$', '')
                $typeMutationCount++
            }
        }
        ConvertTo-Json -InputObject $badTypes -Depth 100 | Set-Content -LiteralPath $testPath -Encoding utf8
        $typeGeneral = (& "$PSScriptRoot/KCPS-ValidateConfig.ps1" -Path $testPath -SnapshotPath $SnapshotPath | Out-String) | ConvertFrom-Json -AsHashtable
        $typeErrors = @($typeGeneral.Groups | ForEach-Object { $_.WorkflowTypeLoadProblems })
        Assert ($typeErrors.Count -eq $typeMutationCount) '主校验未覆盖所有执行单元的 Type 载入格式'
        Assert (@($typeGeneral.Groups | Where-Object { @($_.Problems | Where-Object { $_ -match 'Workflow Type' }).Count -gt 0 }).Count -eq $groups.Count) 'Type 载入失败未进入配置问题汇总'
        $failed = $false
        try {
            $null = & "$PSScriptRoot/KCPS-ValidateConfig.ps1" -Path $testPath -SnapshotPath $SnapshotPath -FailOnProblems
        } catch { $failed = $true }
        Assert $failed 'FailOnProblems没有阻止 Type 载入失败的配置'
    } finally {
        if (Test-Path -LiteralPath $testPath) { Remove-Item -LiteralPath $testPath }
    }
}
[ordered]@{Passed=$script:checks;Failed=0} | ConvertTo-Json
