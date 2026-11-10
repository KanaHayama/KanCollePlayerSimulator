#requires -Version 7.0

param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\KCPS-Common.ps1"

$resolved = Resolve-Path -LiteralPath $Path
$config = Read-KcpsJson -Path $resolved
$groups = @(Get-KcpsGroups -Config $config)
$changes = 0
$reports = @()

foreach ($group in $groups) {
    $workflows = @($group['List'])
    $isEventSortie = @($workflows | Where-Object {
        (Test-KcpsWorkflowType -Workflow $_ -TypeName 'SimpleSortieWorkflow') -and
        [int]$_['Sea'] -eq 0
    }).Count -gt 0
    if (-not $isEventSortie) { continue }

    $refits = @($workflows | Where-Object {
        Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicRefitEquipmentWorkflow'
    })
    foreach ($organize in @($workflows | Where-Object {
        Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicOrganizeFleetWorkflow'
    })) {
        $fleet = [int]$organize['Fleet']
        $positions = @($organize['Positions'])
        for ($index = 0; $index -lt $positions.Count; $index++) {
            $fixedSelections = @($positions[$index]['Selections'] | Where-Object {
                [int]$_['Type'] -eq 0 -and [string]$_['Value'] -match '^\d+$'
            })
            if ($fixedSelections.Count -ne 1 -or @($positions[$index]['Selections']).Count -ne 1) { continue }

            $position = $index + 1
            $shipId = [int]$fixedSelections[0]['Value']
            $matches = @(
                foreach ($refit in $refits) {
                    foreach ($shipRefit in @($refit['Ships'])) {
                        if ([int]$shipRefit['Fleet'] -ne $fleet) { continue }
                        $byPosition = [int]$shipRefit['SelectMethod'] -eq 0 -and
                            [int]$shipRefit['SelectValue'] -eq $position
                        $byId = [int]$shipRefit['SelectMethod'] -eq 3 -and
                            [int]$shipRefit['SelectValue'] -eq $shipId
                        if ($byPosition -or $byId) { $shipRefit }
                    }
                }
            )
            if ($matches.Count -ne 1) {
                $reports += [pscustomobject]@{
                    Group = [string]$group['Name']
                    Fleet = $fleet
                    Position = $position
                    ShipId = $shipId
                    Status = if ($matches.Count -eq 0) { 'MissingRefitRow' } else { 'AmbiguousRefitRows' }
                }
                continue
            }

            $shipRefit = $matches[0]
            if ([int]$shipRefit['SelectMethod'] -ne 3 -or [int]$shipRefit['SelectValue'] -ne $shipId) {
                $shipRefit['SelectMethod'] = 3
                $shipRefit['SelectValue'] = [string]$shipId
                $changes++
            }
            if ([bool]$shipRefit['IgnoreNoShipMatched']) {
                $shipRefit['IgnoreNoShipMatched'] = $false
                $changes++
            }
            foreach ($slot in @($shipRefit['Slots'])) {
                if ([bool]$slot['IgnoreNoEquipmentMatched']) {
                    $slot['IgnoreNoEquipmentMatched'] = $false
                    $changes++
                }
                if ([int]$slot['Slot'] -eq 6) {
                    if (-not [bool]$slot['IgnoreSlotNotAvailable']) {
                        $slot['IgnoreSlotNotAvailable'] = $true
                        $changes++
                    }
                } elseif ([bool]$slot['IgnoreSlotNotAvailable']) {
                    $slot['IgnoreSlotNotAvailable'] = $false
                    $changes++
                }
            }
        }
    }
}

if (-not $CheckOnly -and $changes -gt 0) {
    $json = Write-KcpsJson -Value $config
    [System.IO.File]::WriteAllText(
        [string]$resolved,
        $json + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
    )
}

[ordered]@{
    Path = [string]$resolved
    Mode = if ($CheckOnly) { 'CheckOnly' } else { 'Apply' }
    Changes = $changes
    Reports = @($reports)
} | ConvertTo-Json -Depth 6
