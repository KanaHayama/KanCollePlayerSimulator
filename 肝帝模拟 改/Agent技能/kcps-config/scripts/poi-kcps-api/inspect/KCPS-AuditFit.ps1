#requires -Version 7.0

<#
.SYNOPSIS
    配装契合审计：把配置里每艘船的改装装备，对照 KCPS-FitBonus.json，逐件标注「装備ボーナス(机制A)」和「フィット命中補正/超重(机制B)」，并报出已知踩坑(用了无加成的下位装备、超重未补偿、有更优替代)。
.DESCRIPTION
    装備ボーナス和フィット命中都不在游戏API、规则只在wiki(见 KCPS-FitBonus.json 来源)。本工具是顾问式报告(非pass/fail)：帮你在配装时看清每件装备的契合收益，避免"装了无加成的下位装备/超重炮没补命中"。
    游戏会更新加成，数据以 KCPS-FitBonus.json 的 lastVerifiedJst 为准；本工具只覆盖数据文件里登记的舰，其他舰只列装备不评注。
.EXAMPLE
    KCPS-AuditFit.ps1 -Path "当前出击配置.conf.json"
    KCPS-AuditFit.ps1 -Path "...conf.json" -GroupNameRegex 'P3'
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [string]$GroupNameRegex = '.',
    [string]$FitBonusPath = "$PSScriptRoot\..\data\KCPS-FitBonus.json"
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\KCPS-Common.ps1"

$config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
$fit = Get-Content -LiteralPath $FitBonusPath -Raw | ConvertFrom-Json -AsHashtable
$groups = Get-KcpsGroups -Config $config

# 把船名(从 ship.Memo "舰名 #id" 或 SelectValue)规范成 FitBonus.json 的键
function Resolve-FitShipKey {
    param([hashtable]$ShipBonuses, [string]$ShipMemo, [string]$SelectValue)
    foreach ($name in $ShipBonuses.Keys) {
        if ($ShipMemo -like "*$name*" -or $SelectValue -like "*$name*") { return $name }
    }
    return $null
}

$report = @()

foreach ($group in $groups) {
    if ([string]$group['Name'] -notmatch $GroupNameRegex) { continue }
    $refits = @($group['List'] | Where-Object { Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicRefitEquipmentWorkflow' })
    foreach ($refit in $refits) {
        foreach ($ship in @($refit['Ships'])) {
            $shipMemo = [string]$ship['Memo']
            $sel = [string]$ship['SelectValue']
            $shipKey = Resolve-FitShipKey -ShipBonuses $fit['shipBonuses'] -ShipMemo $shipMemo -SelectValue $sel
            $equips = @()
            foreach ($slot in @($ship['Slots'])) {
                foreach ($eq in @($slot['Equipments'])) {
                    $equips += [string]$eq['SelectValue']
                }
            }

            $annotations = @()
            $issues = @()

            if ($null -ne $shipKey) {
                $sb = $fit['shipBonuses'][$shipKey]['fitBonus']
                $fitHit = $fit['fitHitMechanism']['coefByShip'][$shipKey]
                foreach ($e in $equips) {
                    if ([string]::IsNullOrWhiteSpace($e)) { continue }
                    # 机制A: 找装備ボーナス(子串匹配，最长键优先)
                    # 按「裸名」长度降序匹配，最长(最精确)的裸名优先，避免 改 被误匹配到 無印
                    $bonusKey = $null
                    foreach ($k in ($sb.Keys | Sort-Object { (($_ -split '\[|\(|/')[0]).Length } -Descending)) {
                        $bare = ($k -split '\[|\(|/')[0]
                        if ($e -like "*$bare*" -or $k -like "*$e*") { $bonusKey = $k; break }
                    }
                    if ($bonusKey) {
                        $annotations += "  $e  →[ボーナス] $($sb[$bonusKey])"
                    }
                    # 机制B: 超重(主炮)
                    if ($null -ne $fitHit) {
                        foreach ($gunClass in $fitHit.Keys) {
                            if ($gunClass -eq 'note') { continue }
                            $bareGun = $gunClass -replace '系$',''
                            if ($e -like "*$bareGun*" -or ($gunClass -eq '51cm系' -and $e -like '*51cm*')) {
                                $coef = $fitHit[$gunClass]
                                $tag = if ([int]$coef -lt 0) { "超重(命中$coef×√门)" } elseif ([int]$coef -gt 0) { "フィット(命中+$coef×√门)" } else { "命中±0" }
                                $annotations += "  $e  →[命中フィット] $tag"
                            }
                        }
                    }
                }
            }

            # 已知踩坑(通用，不限登记舰)
            foreach ($e in $equips) {
                if ($e -match '一式徹甲弾$' -or $e -eq '一式徹甲弾') {
                    if ($shipKey -in @('大和改二重','武蔵改二')) { $issues += "用了「一式徹甲弾(無印)」→大和型改二无加成，应换「一式徹甲弾改」(火力+2)" }
                }
                if ($e -match '五連装\(酸素\)魚雷' -and $shipKey -in @('矢矧改二乙','時雨改三')) {
                    $alt = if ($shipKey -eq '時雨改三') { '61cm四連装(酸素)魚雷後期型' } else { '61cm四連装(酸素)魚雷後期型' }
                    $issues += "「61cm五連装(酸素)魚雷」在 $shipKey 上无雷装fit bonus，应换「$alt」(雷装+2/件)"
                }
                if ($e -match '強風' -and $shipKey -eq '矢矧改二乙') {
                    $issues += "矢矧改二乙对水上戦闘機(強風系)无fit bonus；若非为制空而带，考虑换13号対空電探改(火力+1/対空+4/索敵+2/回避+4)或15.2cm連装砲改二(火力+4)"
                }
            }

            $report += [pscustomobject]@{
                Group     = [string]$group['Name']
                Ship      = if ($shipKey) { $shipKey } else { $shipMemo }
                Known     = ($null -ne $shipKey)
                Equips    = @($equips)
                Annotations = @($annotations)
                Issues    = @($issues)
            }
        }
    }
}

[pscustomobject]@{
    Timestamp   = (Get-Date).ToString('s')
    FitBonusVerified = $fit['_meta']['lastVerifiedJst']
    Path        = (Resolve-Path -LiteralPath $Path).Path
    Ships       = @($report)
    IssueCount  = @($report | ForEach-Object { $_.Issues }).Count
} | ConvertTo-KcpsJsonOutput -Depth 40
