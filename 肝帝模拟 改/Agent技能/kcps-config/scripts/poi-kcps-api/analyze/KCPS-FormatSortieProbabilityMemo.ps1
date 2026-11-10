#requires -Version 7.0

param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [switch]$MemoOnly
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\KCPS-AnalysisContract.ps1"

function Format-Percent {
    param([double]$Value)
    $percent = $Value * 100
    if (($percent -gt 0 -and $percent -lt 1) -or ($percent -gt 99 -and $percent -lt 100)) {
        return ('{0:N3}%' -f $percent)
    }
    return ('{0:N1}%' -f $percent)
}

function Get-WilsonInterval {
    param(
        [int]$Successes,
        [int]$Runs
    )

    if ($Runs -le 0) { return $null }
    $z = 1.959963984540054
    $n = [double]$Runs
    $z2 = $z * $z
    $p = $Successes / $n
    $denominator = 1 + ($z2 / $n)
    $centre = ($p + ($z2 / (2 * $n))) / $denominator
    $margin = ($z / $denominator) * [Math]::Sqrt(($p * (1 - $p) / $n) + ($z2 / (4 * $n * $n)))
    return [pscustomobject]@{
        Estimate = $p
        Lower = [Math]::Max([double]0, $centre - $margin)
        Upper = [Math]::Min([double]1, $centre + $margin)
    }
}

function Get-MetricLabel {
    param([string]$Name)

    $labels = @{
        TargetReachRate = '到达目标点'
        RetreatRate = '道中撤退'
        FlagshipSinkRate = '敌旗舰击沉'
        RankSRate = 'S胜'
        RankAOrBetterRate = 'A胜以上'
        RankBOrBetterRate = 'B胜以上'
        JointTargetSuccessRate = '到达目标点且满足胜利条件'
        TwoSuccessesInTwoSortiesRate = '恰好两次出击完成两次S胜'
        AllRequiredSuccessesInMinimumSortiesRate = '最少出击次数内全部成功'
        AirStateTargetRate = '达到目标制空状态'
        AverageGaugeDamage = '每次出击平均削减'
        AverageTP = '每次出击平均TP'
        AverageBuckets = '每次出击平均高速修复'
        AverageFuel = '每次出击平均燃料'
        AverageAmmo = '每次出击平均弹药'
        AverageBauxite = '每次出击平均铝'
        ExpectedSorties = '完成目标平均出击次数'
    }
    if ($labels.ContainsKey($Name)) { return $labels[$Name] }
    return $Name
}

$analysis = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
$problems = @()
try {
    $validSchema = Test-Json -Json ($analysis | ConvertTo-Json -Depth 100 -Compress) -SchemaFile (Join-Path $script:KcpsAnalysisSchemaRoot 'KCPS-SortieAnalysisResult.schema.json') -ErrorAction Stop
    if (-not $validSchema) { $problems += '分析结果不符合版本2契约。' }
} catch { $problems += '分析结果不符合版本2契约。' }

if ([int]$analysis['SchemaVersion'] -ne 2) {
    $problems += 'SchemaVersion 必须为 2；旧结果缺少可追溯的初始状态。'
}

$assumptions = $analysis['Assumptions']
try { Assert-KcpsAnalysisAssumptions -Assumptions $assumptions } catch { $problems += $_.Exception.Message }

$stages = @($analysis['Stages'])
if ($stages.Count -eq 0) {
    $problems += 'Stages 至少要有一个阶段。'
}
if ($problems.Count -gt 0) { throw ('出击概率分析结果无效：' + ($problems -join '；')) }

$memoLines = [System.Collections.Generic.List[string]]::new()
$memoLines.Add('【出击概率分析】')
$memoLines.Add('以下均为模型估算，不是游戏结果保证。')

$simulator = $analysis['Simulator']
if ($null -ne $simulator) {
    $revision = [string]$simulator['Revision']
    if ($revision.Length -gt 12) { $revision = $revision.Substring(0, 12) }
    $memoLines.Add(('模拟器：{0}，版本 {1}。' -f $simulator['Name'], $revision))
}

if ($null -ne $assumptions) {
    $kindLabel = if ($assumptions['StateKind'] -eq 'Baseline') { '显式对照基线，不代表账号实际状态' } else { '按所提供的实际状态' }
    $memoLines.Add(('初始状态：{0}；来源：{1}。' -f $kindLabel, $assumptions['Source']))
    $memoLines.Add(('状态策略：{0}；{1}；{2}。' -f $assumptions['SupplyPolicy'], $assumptions['StartingHpPolicy'], $assumptions['MoralePolicy']))
    $stateRows = @($assumptions['ResolvedShips'] | ForEach-Object {
        'HP {0}/{1}，燃料 {2:P0}，弹药 {3:P0}，士气 {4}' -f $_['Hp'], $_['MaxHp'], $_['FuelFraction'], $_['AmmoFraction'], $_['Morale']
    })
    $memoLines.Add(('逐舰起始值（按出击顺序）：{0}。' -f ($stateRows -join '；')))
    $ranks = @($assumptions['ShipAircraftProficiency']['Equipment'] | ForEach-Object { $_['DisplayRank'] } | Sort-Object -Unique)
    $memoLines.Add(('飞机显示熟练度：{0}；精确内部熟练度未建模。陆航：{1}。' -f $(if ($ranks.Count) { $ranks -join '、' } else { '无适用飞机' }), $assumptions['LandBaseAircraftProficiency']['Reason']))
    if ($assumptions.ContainsKey('EventBonusPolicy')) {
        $memoLines.Add(('活动增伤：{0}。' -f ([string]$assumptions['EventBonusPolicy']).TrimEnd('。')))
    }
    if ($assumptions['BonusRole'] -eq 'Sensitivity') { $memoLines.Add('本结果为敏感性对照，不替代主模型估计。') }
    if ($assumptions.ContainsKey('DependencyPolicy')) {
        $memoLines.Add(('状态依赖：{0}。' -f ([string]$assumptions['DependencyPolicy']).TrimEnd('。')))
    }
}

foreach ($stage in $stages) {
    $memoLines.Add('')
    $memoLines.Add(('【{0}】' -f $stage['Label']))
    $memoLines.Add(('目标：{0}。' -f $stage['Goal']))

    if (-not [bool]$stage['Reliable']) {
        $reason = [string]$stage['UnavailableReason']
        if ([string]::IsNullOrWhiteSpace($reason)) {
            $problems += "$($stage['Label']) 标为不可靠时必须填写 UnavailableReason。"
            $reason = '缺少可说明的原因'
        }
        $memoLines.Add(('未生成可靠估算：{0}。' -f $reason.TrimEnd('。')))
    } else {
        $runs = [int]$stage['Runs']
        $successes = [int]$stage['Successes']
        $seedCount = [int]$stage['SeedCount']
        if ($runs -le 0 -or $successes -lt 0 -or $successes -gt $runs -or $seedCount -le 0) {
            $problems += "$($stage['Label']) 的 Runs、Successes 或 SeedCount 无效。"
        } else {
            $interval = Get-WilsonInterval -Successes $successes -Runs $runs
            $memoLines.Add(('单次达成：{0}（95%抽样区间 {1}–{2}，{3} 次模拟，{4} 个种子）。' -f
                (Format-Percent $interval.Estimate),
                (Format-Percent $interval.Lower),
                (Format-Percent $interval.Upper),
                $runs,
                $seedCount))

            $requiredSuccesses = if ($stage.ContainsKey('RequiredSuccessCount')) {
                [int]$stage['RequiredSuccessCount']
            } else {
                1
            }
            $independentRepeatedSuccesses = (
                $stage.ContainsKey('IndependentRepeatedSuccesses') -and
                [bool]$stage['IndependentRepeatedSuccesses']
            )
            if ($interval.Estimate -gt 0 -and $independentRepeatedSuccesses) {
                $expectedAttempts = $requiredSuccesses / $interval.Estimate
                $memoLines.Add(('按独立同分布近似，累计完成 {0} 次成功平均需 {1:N2} 次出击。' -f
                    $requiredSuccesses, $expectedAttempts))
            }
        }
    }

    $metrics = $stage['Metrics']
    if ($null -ne $metrics -and [bool]$stage['Reliable']) {
        foreach ($entry in $metrics.GetEnumerator()) {
            $label = Get-MetricLabel -Name ([string]$entry.Key)
            $value = [double]$entry.Value
            if ([string]$entry.Key -match 'Rate$') {
                if ($value -lt 0 -or $value -gt 1) {
                    $problems += "$($stage['Label']) 的指标 $($entry.Key) 必须在 0..1。"
                    continue
                }
                $memoLines.Add(('{0}：{1}。' -f $label, (Format-Percent $value)))
            } else {
                $memoLines.Add(('{0}：{1:N2}。' -f $label, $value))
            }
        }
    }

    $confidence = [string]$stage['ModelConfidence']
    if ($confidence -notin @('A', 'B', 'C')) {
        $problems += "$($stage['Label']) 的 ModelConfidence 必须为 A、B 或 C。"
    }
    $uncertainties = @($stage['Uncertainties'] | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $memoLines.Add(('模型可信度：{0}。' -f $confidence))
    $memoLines.Add('主要不确定性：')
    if ($uncertainties.Count -eq 0) {
        $memoLines.Add('- 未记录。')
    } else {
        foreach ($uncertainty in $uncertainties) {
            $memoLines.Add(('- {0}。' -f ([string]$uncertainty).TrimEnd('。')))
        }
    }
}

$memo = $memoLines -join [Environment]::NewLine
$result = [pscustomobject]@{
    Valid = ($problems.Count -eq 0)
    Problems = @($problems)
    Memo = $memo
}

if ($problems.Count -gt 0) {
    throw ('出击概率分析结果无效：' + ($problems -join '；'))
}
if ($MemoOnly) {
    $memo
} else {
    $result | ConvertTo-Json -Depth 8
}

