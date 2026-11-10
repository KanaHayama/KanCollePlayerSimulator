#requires -Version 7.0

param(
    [int[]]$ExpeditionId = @(),
    [string]$DefaultPath = '',
    [int[]]$BattleOrSupportExpeditionIds = @(33, 34),
    [switch]$IncludeBattleOrSupport,
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot\..\poi-kcps-api\KCPS-Connection.ps1"
$DefaultPath = Resolve-KcpsDefaultConfigPath -Path $DefaultPath

function Split-IntList {
    param([int[]]$Values)
    @($Values | ForEach-Object { [int]$_ })
}

function Get-ShortType {
    param([object]$Workflow)
    (($Workflow['Type'] -as [string]) -split ',')[0]
}

$targetIds = @(Split-IntList -Values $ExpeditionId)
$battleIds = @(Split-IntList -Values $BattleOrSupportExpeditionIds)

$cfg = Get-Content -LiteralPath $DefaultPath -Raw | ConvertFrom-Json -AsHashtable
$roots = if ($cfg -is [array]) { @($cfg) } else { @($cfg) }

$items = @()
$index = 0
foreach ($root in $roots) {
    $index++
    if (-not ($root -is [hashtable]) -or -not $root.ContainsKey('List')) {
        continue
    }

    $list = @($root['List'])
    $simple = @($list | Where-Object { (Get-ShortType $_) -eq 'KancollePlayerSimulatorKai.SimpleExpeditionWorkflow' })
    if ($simple.Count -eq 0) { continue }

    foreach ($send in $simple) {
        $missionId = [int]$send['Expedition']
        if ($targetIds.Count -gt 0 -and -not ($targetIds -contains $missionId)) {
            continue
        }

        $isBattle = $battleIds -contains $missionId
        if ($isBattle -and -not $IncludeBattleOrSupport) {
            continue
        }

        $rel = @($list | Where-Object { (Get-ShortType $_) -eq 'KancollePlayerSimulatorKai.RelationalExpeditionWorkflow' -and $_['ExpeditionWorkflow']['Guid'] -eq $send['Guid'] })
        $org = @($list | Where-Object { (Get-ShortType $_) -eq 'KancollePlayerSimulatorKai.BasicOrganizeFleetWorkflow' } | Select-Object -First 1)
        $refit = @($list | Where-Object { (Get-ShortType $_) -eq 'KancollePlayerSimulatorKai.BasicRefitEquipmentWorkflow' } | Select-Object -First 1)

        $positionSelectors = @()
        if ($org.Count -gt 0 -and $org[0].ContainsKey('Positions')) {
            $posIndex = 0
            foreach ($pos in $org[0]['Positions']) {
                $posIndex++
                $selectionText = @($pos['Selections'] | ForEach-Object { "$($_['Type']):$($_['Value'])" }) -join ';'
                $positionSelectors += [pscustomobject]@{
                    Position = $posIndex
                    Selections = $selectionText
                    SkipExpeditioningShips = $pos['SkipExpeditioningShips']
                    SkipShipsInOtherFleets = $pos['SkipShipsInOtherFleets']
                    SkipMoraleMax = $pos['SkipMoraleInRangeValueMax']
                    SortingMethod = $pos['SelectionSortingMethod']
                }
            }
        }

        $refitSummary = @()
        if ($refit.Count -gt 0 -and $refit[0].ContainsKey('Ships')) {
            foreach ($ship in $refit[0]['Ships']) {
                $slotSummary = @($ship['Slots'] | ForEach-Object {
                    $values = @($_['Equipments'] | ForEach-Object { $_['SelectValue'] }) -join '|'
                    "slot$($_['Slot'])=$values"
                }) -join ';'
                $refitSummary += [pscustomobject]@{
                    Fleet = $ship['Fleet']
                    SelectMethod = $ship['SelectMethod']
                    SelectValue = $ship['SelectValue']
                    Slots = $slotSummary
                }
            }
        }

        $items += [pscustomobject]@{
            RootIndex = $index
            RootName = $root['Name']
            ExpeditionId = $missionId
            Fleet = $send['Fleet']
            IsBattleOrSupport = $isBattle
            RelationalGuid = $(if ($rel.Count -gt 0) { $rel[0]['Guid'] } else { $null })
            OrganizeGuid = $(if ($org.Count -gt 0) { $org[0]['Guid'] } else { $null })
            RefitGuid = $(if ($refit.Count -gt 0) { $refit[0]['Guid'] } else { $null })
            SendGuid = $send['Guid']
            OrganizeScript = $(if ($org.Count -gt 0) { $org[0]['Script'] } else { $null })
            SendCheckerEnabled = $send['EnableScriptChecker']
            SendCheckerName = $send['ScriptCheckerName']
            SendCheckerScript = $send['Script']
            PositionSelectors = @($positionSelectors)
            RefitSummary = @($refitSummary)
        }
    }
}

if ($AsJson) {
    if ($items.Count -eq 0) {
        '[]'
    } else {
        $items | ConvertTo-Json -Depth 80
    }
} else {
    $items
}
