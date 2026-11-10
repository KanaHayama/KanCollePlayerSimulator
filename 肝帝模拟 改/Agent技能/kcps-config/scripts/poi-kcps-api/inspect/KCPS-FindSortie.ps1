#requires -Version 7.0

param(
    [int]$Sea = 0,
    [int]$Area = 0,
    [string]$NameContains = '',
    [string]$DefaultPath = ''
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\KCPS-Common.ps1"

$DefaultPath = Resolve-KcpsDefaultConfigPath -Path $DefaultPath
$root = Read-KcpsJson -Path $DefaultPath
$matches = @()

for ($groupIndex = 0; $groupIndex -lt $root.Count; $groupIndex++) {
    $group = $root[$groupIndex]
    if (-not $group.ContainsKey('List') -or $null -eq $group['List']) { continue }
    for ($workflowIndex = 0; $workflowIndex -lt $group['List'].Count; $workflowIndex++) {
        $workflow = $group['List'][$workflowIndex]
        if ($null -eq $workflow -or -not ($workflow['Type'] -as [string]).Contains('SimpleSortieWorkflow')) { continue }
        if ($Sea -ne 0 -and [int]$workflow['Sea'] -ne $Sea) { continue }
        if ($Area -ne 0 -and [int]$workflow['Area'] -ne $Area) { continue }
        if ($NameContains -and -not (($workflow['Name'] -as [string]).Contains($NameContains))) { continue }

        $strategies = foreach ($strategy in $workflow['Strategies']) {
            [pscustomobject]@{
                ConditionType = $strategy['Condition']['Type']
                Point = $strategy['Condition']['Value']
                Memo = $strategy['Strategy']['Memo']
                Formation = $strategy['Strategy']['DefaultFormation']
                Advance = $strategy['Strategy']['DefaultAdvance']
                Midnight = $strategy['Strategy']['DefaultMidnight']
            }
        }

        $matches += [pscustomobject]@{
            GroupIndex = $groupIndex
            WorkflowIndex = $workflowIndex
            Group = $group['Name']
            Name = $workflow['Name']
            Sea = $workflow['Sea']
            Area = $workflow['Area']
            Fleet = $workflow['Fleet']
            FlagShipMorale = $workflow['FlagShipMoraleLargerOrEqualThanValue']
            EscortMorale = $workflow['EscortShipMoraleLargerOrEqualThanValue']
            NoHeavyDamageAdvance = $workflow['EscortShipNoHeavilyDamaged']
            Strategies = @($strategies)
        }
    }
}

$matches | ConvertTo-KcpsJsonOutput -Depth 20
