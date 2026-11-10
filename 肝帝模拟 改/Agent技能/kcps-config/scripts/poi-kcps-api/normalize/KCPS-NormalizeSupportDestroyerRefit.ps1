#requires -Version 7.0
# Inspection only: never invent equipment or alter declared optional slots.
param([Parameter(Mandatory)][string]$Path,[switch]$CheckOnly)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\..\KCPS-Common.ps1"
$config=Read-KcpsJson $Path
$reports=@()
foreach($group in @(Get-KcpsGroups $config)) {
    $workflows=@($group['List'])
    foreach($org in @($workflows | Where-Object {Test-KcpsWorkflowType $_ 'BasicOrganizeFleetWorkflow'})) {
        $positions=@($org['Positions'])
        for($i=0;$i -lt $positions.Count;$i++) {
            if(@($positions[$i]['Selections']|Where-Object {[int]$_['Type'] -eq 8}).Count -eq 0){continue}
            $rows=@($workflows|Where-Object {Test-KcpsWorkflowType $_ 'BasicRefitEquipmentWorkflow'}|ForEach-Object {$_['Ships']}|Where-Object {[int]$_['Fleet'] -eq [int]$org['Fleet'] -and [int]$_['SelectMethod'] -eq 0 -and [int]$_['SelectValue'] -eq ($i+1)})
            $status=if($rows.Count -ne 1){'MissingOrAmbiguousRefitRow'}elseif(@($rows[0]['Slots']).Count -eq 0){'MissingDeclaredLoadout'}else{''}
            if($status){$reports+=@{Group=$group['Name'];Fleet=$org['Fleet'];Position=$i+1;Status=$status;Problem='请根据本次角色方案明示配装；检查器不会补入默认装备。'}}
        }
    }
}
@{Path=(Resolve-Path -LiteralPath $Path).Path;Mode='InspectionOnly';Changes=0;Reports=@($reports)}|ConvertTo-Json -Depth 8
