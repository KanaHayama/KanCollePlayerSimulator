#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Single', 'Combined')]
    [string]$FleetMode,

    [Parameter(Mandatory = $true)]
    [string]$LandBasedAirCorpsSpecJson,

    [ValidateSet(0, 6, 7)]
    [int]$LandBasedAirCorpsSea = 0,

    [string]$BaseUrl = '',

    [string]$SnapshotPath = '',

    [string]$TpBaselineSpecJson,

    [string[]]$GroupName,

    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\KCPS-Common.ps1"
$const = if ([string]::IsNullOrWhiteSpace($SnapshotPath)) {
    Get-PoiData -Type const -BaseUrl $BaseUrl
} else {
    (Get-Content -LiteralPath $SnapshotPath -Raw | ConvertFrom-Json -AsHashtable)['const']
}

function ConvertTo-PythonString {
    param([AllowEmptyString()][string]$Value)

    return ($Value | ConvertTo-Json -Compress)
}

function Get-SelectedShipSpec {
    param(
        [System.Collections.IDictionary]$Group,
        [int]$Fleet
    )

    $organize = @($Group['List'] | Where-Object {
        (Test-KcpsWorkflowType -Workflow $_ -TypeName 'BasicOrganizeFleetWorkflow') -and
        [int]$_['Fleet'] -eq $Fleet
    })
    if ($organize.Count -ne 1) {
        throw "Group '$($Group['Name'])' must contain exactly one fixed organize workflow for fleet $Fleet."
    }

    $result = @()
    $position = 0
    foreach ($row in @($organize[0]['Positions'])) {
        $position++
        $selections = @($row['Selections'])
        if ($selections.Count -ne 1 -or [int]$selections[0]['Type'] -ne 0) {
            throw "Group '$($Group['Name'])' fleet $Fleet position $position is not one fixed ship-id candidate."
        }
        $id = [int]$selections[0]['Value']
        if ($id -le 0) {
            throw "Group '$($Group['Name'])' fleet $Fleet position $position has an invalid ship id."
        }
        $name = ([string]$selections[0]['Memo']).Trim().Trim([char[]]'[]')
        if ([string]::IsNullOrWhiteSpace($name)) {
            $name = "舰船ID $id"
        }
        $result += [ordered]@{
            Id = $id
            Name = $name
        }
    }
    if ($result.Count -eq 0) {
        throw "Group '$($Group['Name'])' fleet $Fleet has no configured ship positions."
    }
    return @($result)
}

function Get-UsedLandBasedAirCorpsNumbers {
    param([System.Collections.IDictionary]$Sortie)

    $result = @()
    foreach ($number in 1..3) {
        $action = [int]$Sortie["LandBasedAirCorps${number}Action"]
        if ($action -in @(1, 2)) {
            $result += $number
        }
    }
    return @($result)
}

function Convert-LandBasedAirCorpsSpec {
    param(
        [string]$Json,
        [int[]]$UsedNumbers,
        [string]$Group,
        [System.Collections.IDictionary]$Const
    )

    $raw = $Json | ConvertFrom-Json -AsHashtable
    if ($raw -isnot [System.Collections.IDictionary]) {
        throw 'LandBasedAirCorpsSpecJson must be a JSON object keyed by corps number.'
    }

    $specNumbers = @($raw.Keys | ForEach-Object { [int]$_ } | Sort-Object)
    $expectedNumbers = @($UsedNumbers | Sort-Object)
    if (($specNumbers -join ',') -ne ($expectedNumbers -join ',')) {
        throw "Group '$Group' uses land bases [$($expectedNumbers -join ',')], but the supplied specification contains [$($specNumbers -join ',')]."
    }

    $result = [ordered]@{}
    foreach ($number in $expectedNumbers) {
        $rows = @($raw[[string]$number])
        if ($rows.Count -ne 4) {
            throw "Group '$Group' land base $number must specify exactly four slots."
        }
        $normalized = @()
        $slot = 0
        foreach ($row in $rows) {
            $slot++
            if ($row -isnot [System.Collections.IDictionary]) {
                throw "Group '$Group' land base $number slot $slot must contain Id and Name."
            }
            $id = [int]$row['Id']
            $name = ([string]$row['Name']).Trim()
            if ($id -le 0 -or [string]::IsNullOrWhiteSpace($name)) {
                throw "Group '$Group' land base $number slot $slot has an invalid Id or Name."
            }
            $masterName = Get-KcpsConstEquipName -Const $Const -EquipConstId $id
            $normalizedName = Normalize-KcpsEquipmentDisplayName -Name $name
            if ($masterName -eq "#$id") {
                throw "Group '$Group' land base $number slot $slot refers to unknown equipment master id $id."
            }
            if ($masterName -cne $normalizedName) {
                throw "Group '$Group' land base $number slot $slot equipment id/name mismatch: id $id is '$masterName', not '$name'."
            }
            $normalized += [ordered]@{
                Id = $id
                Name = $name
            }
        }
        $result[[string]$number] = @($normalized)
    }
    return $result
}

function Convert-TpBaselineSpecs {
    param(
        [AllowEmptyString()][string]$Json,
        [System.Collections.IDictionary[]]$Groups
    )

    $result = [ordered]@{}
    if ([string]::IsNullOrWhiteSpace($Json)) {
        return $result
    }

    $raw = $Json | ConvertFrom-Json -AsHashtable
    if ($raw -isnot [System.Collections.IDictionary]) {
        throw 'TpBaselineSpecJson must be a JSON object keyed by group name.'
    }

    $groupNames = @($Groups | ForEach-Object { [string]$_['Name'] })
    foreach ($name in @($raw.Keys)) {
        if ($name -notin $groupNames) {
            throw "TP baseline specification refers to unknown group '$name'."
        }
        $row = $raw[$name]
        if ($row -isnot [System.Collections.IDictionary]) {
            throw "TP baseline specification for group '$name' must be an object."
        }
        $area = [int]$row['Area']
        $gaugeNumber = [int]$row['GaugeNumber']
        $messagePrefix = ([string]$row['MessagePrefix']).Trim()
        if ($area -le 0 -or $gaugeNumber -le 0 -or
            [string]::IsNullOrWhiteSpace($messagePrefix) -or $messagePrefix.Contains('|')) {
            throw "TP baseline specification for group '$name' must contain positive Area/GaugeNumber and a non-empty MessagePrefix without '|'."
        }
        $result[$name] = [ordered]@{
            Area = $area
            GaugeNumber = $gaugeNumber
            MessagePrefix = $messagePrefix
        }
    }
    return $result
}

function Convert-SpecMapToPython {
    param(
        [System.Collections.IDictionary]$Map,
        [string]$IdKey
    )

    $lines = @('{')
    foreach ($key in @($Map.Keys | Sort-Object { [int]$_ })) {
        $lines += "    ${key}: ["
        foreach ($row in @($Map[$key])) {
            $lines += "        ($([int]$row[$IdKey]), $(ConvertTo-PythonString -Value ([string]$row['Name']))),"
        }
        $lines += '    ],'
    }
    $lines += '}'
    return ($lines -join "`n")
}

function New-SortieIdentityCheckerScript {
    param(
        [string]$Mode,
        [System.Collections.IDictionary]$FleetSpec,
        [System.Collections.IDictionary]$LandBaseSpec,
        [int]$Sea,
        [AllowNull()][System.Collections.IDictionary]$TpBaselineSpec
    )

    $metadata = [ordered]@{
        Version = 3
        FleetMode = $Mode
        Fleets = $FleetSpec
        LandBasedAirCorpsSea = $Sea
        LandBases = $LandBaseSpec
        TpBaseline = $TpBaselineSpec
    } | ConvertTo-Json -Depth 20 -Compress
    $fleetPython = Convert-SpecMapToPython -Map $FleetSpec -IdKey 'Id'
    $landBasePython = Convert-SpecMapToPython -Map $LandBaseSpec -IdKey 'Id'
    $seaName = switch ($Sea) {
        0 { 'SeaEvent' }
        6 { 'Sea6' }
        7 { 'Sea7' }
    }
    $tpBaselinePython = if ($null -eq $TpBaselineSpec) {
        'TP_BASELINE = None'
    } else {
        "TP_BASELINE = ($([int]$TpBaselineSpec['Area']), $([int]$TpBaselineSpec['GaugeNumber']), $(ConvertTo-PythonString -Value ([string]$TpBaselineSpec['MessagePrefix'])))"
    }

    return @"
# KCPS_SORTIE_IDENTITY_CHECKER_BEGIN
# KCPS_SORTIE_IDENTITY_CHECKER_SPEC $metadata
from KancollePlayerSimulatorKaiCore import *

EXPECTED_FLEETS = $fleetPython
EXPECTED_LAND_BASES = $landBasePython
LAND_BASE_SEA = LandBasedAirCorpsSea.$seaName
$tpBaselinePython
LAND_BASE_NUMBERS = {
    1: LandBasedAirCorps.Corps1,
    2: LandBasedAirCorps.Corps2,
    3: LandBasedAirCorps.Corps3,
}

def _check_fleets():
    # 只核对指定舰队
    valid = True
    for fleet_no, expected in EXPECTED_FLEETS.items():
        expected_ids = [row[0] for row in expected]
        actual_ids = list(FleetUtility.Ships(fleet_no))
        count = max(len(expected_ids), len(actual_ids))
        for index in range(count):
            expected_id = expected_ids[index] if index < len(expected_ids) else 0
            actual_id = actual_ids[index] if index < len(actual_ids) else 0
            if expected_id == actual_id:
                continue
            expected_text = expected[index][1] if index < len(expected) else "空"
            actual_text = ShipUtility.HumanReadable(actual_id) if actual_id > 0 else "空"
            Logger.Error("第{0}舰队第{1}位舰船不符：应为{2}；实际为{3}".format(
                fleet_no, index + 1, expected_text, actual_text))
            valid = False
    return valid

def _read_land_base(corps):
    ids = {}
    names = {}
    for squadron in LandBasedAirCorpsUtility.AllSquadrons(corps):
        slot = int(LandBasedAirCorpsUtility.SquadronId(squadron))
        instance_id = LandBasedAirCorpsUtility.SquadronAirplaneEquipmentId(squadron)
        if instance_id is not None and instance_id > 0:
            ids[slot] = EquipmentUtility.ConstId(instance_id)
            names[slot] = EquipmentUtility.HumanReadable(instance_id)
        else:
            ids[slot] = 0
            names[slot] = "空或配置转换中" if instance_id is None else "空"
    return ([ids.get(slot, 0) for slot in range(1, 5)],
            [names.get(slot, "空") for slot in range(1, 5)])

def _check_land_bases():
    # 只核对指定陆航
    valid = True
    for corps_no, expected in EXPECTED_LAND_BASES.items():
        corps = LandBasedAirCorpsUtility.Corps(LAND_BASE_SEA, LAND_BASE_NUMBERS[corps_no])
        if corps is None:
            Logger.Error("第{0}基地航空队未开放或数据不存在".format(corps_no))
            valid = False
            continue
        actual_ids, actual_names = _read_land_base(corps)
        for index in range(4):
            if actual_ids[index] == expected[index][0]:
                continue
            Logger.Error("第{0}基地航空队第{1}槽飞机不符：应为{2}；实际为{3}".format(
                corps_no, index + 1, expected[index][1], actual_names[index]))
            valid = False
    return valid

def _capture_tp_baseline():
    # 出击前刷新并发送本轮TP基线
    if TP_BASELINE is None:
        return True
    area, expected_gauge_num, message_prefix = TP_BASELINE
    m = MapUtility.Map(Sea.SeaEvent, area, MiscApi.Maps())
    if m is None:
        Logger.Error("出击前无法读取活动海域{0}的量值".format(area))
        return False
    gauge = MapUtility.Gauge(m)
    tp = MapUtility.CurrentHp(m)
    gauge_num = None
    try:
        token = m["api_gauge_num"]
        if token is not None:
            gauge_num = int(str(token))
    except:
        pass
    if gauge != MapGauge.Tp or tp is None:
        Logger.Error("出击前量值已不是TP条")
        return False
    if gauge_num != expected_gauge_num:
        Logger.Error("出击前TP阶段不符：应为{0}；实际为{1}".format(
            expected_gauge_num, gauge_num))
        return False
    Utility.RaiseEvent(UserEvent("{0}|{1}|{2}".format(
        message_prefix, gauge_num, tp)))
    return True

def OnCheckSortieFleetAndLandBases():
    if not _check_fleets():
        return False
    if not _check_land_bases():
        return False
    return _capture_tp_baseline()
# KCPS_SORTIE_IDENTITY_CHECKER_END
"@.Trim()
}

function Set-CheckerBlock {
    param(
        [AllowNull()][string]$ExistingScript,
        [string]$CheckerBlock
    )

    $begin = '# KCPS_SORTIE_IDENTITY_CHECKER_BEGIN'
    $end = '# KCPS_SORTIE_IDENTITY_CHECKER_END'
    $existing = [string]$ExistingScript
    if ($existing.Contains($begin)) {
        $pattern = '(?ms)^' + [regex]::Escape($begin) + '.*?^' + [regex]::Escape($end) + '\s*'
        return ([regex]::Replace($existing, $pattern, $CheckerBlock + "`n")).Trim()
    }
    if ($existing -match '(?m)^\s*def\s+OnCheckSortieFleetAndLandBases\s*\(') {
        throw 'Script already defines OnCheckSortieFleetAndLandBases without the managed marker.'
    }
    if ([string]::IsNullOrWhiteSpace($existing)) {
        return $CheckerBlock
    }
    return ($existing.TrimEnd() + "`n`n" + $CheckerBlock)
}

$config = Read-KcpsJson -Path $Path
$groups = @(Get-KcpsGroups -Config $config)
$selectedGroups = @($groups | Where-Object {
    $null -eq $GroupName -or $GroupName.Count -eq 0 -or
        $GroupName -contains [string]$_['Name']
})
if ($selectedGroups.Count -eq 0) {
    throw 'No matching workflow group was found.'
}
$tpBaselineSpecs = Convert-TpBaselineSpecs -Json $TpBaselineSpecJson -Groups $selectedGroups

$reports = @()
$pending = 0
foreach ($group in $selectedGroups) {
    $sorties = @($group['List'] | Where-Object {
        Test-KcpsWorkflowType -Workflow $_ -TypeName 'SimpleSortieWorkflow'
    })
    if ($sorties.Count -ne 1) {
        throw "Group '$($group['Name'])' must contain exactly one SimpleSortieWorkflow."
    }
    $sortie = $sorties[0]
    $fleetNumbers = if ($FleetMode -eq 'Combined') { @(1, 2) } else { @([int]$sortie['Fleet']) }
    $fleetSpec = [ordered]@{}
    foreach ($fleet in $fleetNumbers) {
        $fleetSpec[[string]$fleet] = @(Get-SelectedShipSpec -Group $group -Fleet $fleet)
    }
    $allShipIds = @($fleetSpec.Values | ForEach-Object { $_ } | ForEach-Object { [int]$_['Id'] })
    if (@($allShipIds | Sort-Object -Unique).Count -ne $allShipIds.Count) {
        throw "Group '$($group['Name'])' repeats a ship instance across checked fleets."
    }

    $usedLandBases = @(Get-UsedLandBasedAirCorpsNumbers -Sortie $sortie)
    $landBaseSpec = Convert-LandBasedAirCorpsSpec -Json $LandBasedAirCorpsSpecJson -UsedNumbers $usedLandBases -Group ([string]$group['Name']) -Const $const
    $tpBaselineSpec = if ($tpBaselineSpecs.Contains([string]$group['Name'])) {
        $tpBaselineSpecs[[string]$group['Name']]
    } else {
        $null
    }
    $checker = New-SortieIdentityCheckerScript -Mode $FleetMode -FleetSpec $fleetSpec -LandBaseSpec $landBaseSpec -Sea $LandBasedAirCorpsSea -TpBaselineSpec $tpBaselineSpec
    $newScript = Set-CheckerBlock -ExistingScript ([string]$sortie['Script']) -CheckerBlock $checker

    $changed = -not [bool]$sortie['EnableScriptSortieChecker'] -or
        [string]$sortie['SoriteCheckerFunctionName'] -ne 'OnCheckSortieFleetAndLandBases' -or
        [string]$sortie['Script'] -cne $newScript
    if ($changed) {
        $pending++
        if (-not $CheckOnly) {
            $sortie['EnableScriptSortieChecker'] = $true
            $sortie['SoriteCheckerFunctionName'] = 'OnCheckSortieFleetAndLandBases'
            $sortie['EnableScript'] = $true
            $sortie['Script'] = $newScript
        }
    }

    $reports += [ordered]@{
        Group = [string]$group['Name']
        FleetMode = $FleetMode
        Fleets = $fleetSpec
        LandBases = $landBaseSpec
        TpBaseline = $tpBaselineSpec
        Changed = $changed
    }
}

if (-not $CheckOnly -and $pending -gt 0) {
    $json = Write-KcpsJson -Value $config
    [System.IO.File]::WriteAllText(
        (Resolve-Path -LiteralPath $Path).Path,
        $json,
        [System.Text.UTF8Encoding]::new($false)
    )
}

[ordered]@{
    Path = (Resolve-Path -LiteralPath $Path).Path
    CheckOnly = [bool]$CheckOnly
    PendingChangeCount = $pending
    Groups = @($reports)
} | ConvertTo-Json -Depth 30
