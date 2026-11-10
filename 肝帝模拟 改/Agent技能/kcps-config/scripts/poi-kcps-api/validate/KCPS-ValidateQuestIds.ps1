#requires -Version 7.0

param(
    [Parameter(Mandatory = $true)]
    [string[]]$Path,

    [string]$BaseUrl = ''
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\KCPS-Common.ps1"

function Normalize-QuestText {
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    return ($Value -replace '\s+', '' -replace '<br\s*/?>', '' -replace '^[A-Za-z]+\d+\s*', '')
}

$questList = Get-PoiQuestList -BaseUrl $BaseUrl
$questMap = @{}
foreach ($quest in @($questList['api_list'])) {
    if ($quest -isnot [hashtable] -or -not $quest.ContainsKey('api_no')) { continue }
    $questMap[[string]$quest['api_no']] = $quest
}

$reports = @()
foreach ($pathValue in $Path) {
    $resolvedPath = (Resolve-Path -LiteralPath $pathValue).Path
    $config = Get-Content -LiteralPath $resolvedPath -Raw | ConvertFrom-Json -AsHashtable
    $entries = @()
    $problems = @()

    foreach ($group in Get-KcpsGroups -Config $config) {
        $groupName = [string]$group['Name']
        foreach ($workflow in @($group['List'])) {
            if (-not (Test-KcpsWorkflowType -Workflow $workflow -TypeName 'BasicAcceptQuestWorkflow')) { continue }
            foreach ($selector in @($workflow['Quests'])) {
                $id = [string]$selector['SelectValue']
                $memo = [string]$selector['Memo']
                $status = 'OK'
                $liveTitle = $null
                $problem = $null

                if ([int]$selector['SelectMethod'] -ne 0) {
                    $status = 'UnsupportedSelectMethod'
                    $problem = "$groupName / $($workflow['Name']): quest selector must use game api_no ID."
                } elseif ($id -notmatch '^\d+$') {
                    $status = 'InvalidId'
                    $problem = "$groupName / $($workflow['Name']): quest id '$id' is not numeric."
                } elseif (-not $questMap.ContainsKey($id)) {
                    $status = 'NotFoundInLiveApi'
                    $problem = "$groupName / $($workflow['Name']): quest id $id is not present in the current game API quest list."
                } else {
                    $liveTitle = [string]$questMap[$id]['api_title']
                    $titleNorm = Normalize-QuestText $liveTitle
                    $memoNorm = Normalize-QuestText "$memo $groupName"
                    if ($memoNorm -notlike "*$titleNorm*") {
                        $status = 'TitleMismatch'
                        $problem = "$groupName / $($workflow['Name']): quest id $id is '$liveTitle', but memo/group is '$memo'."
                    }
                }

                if (-not [bool]$selector['FailIfNotExist']) {
                    $problems += "$groupName / $($workflow['Name']): FailIfNotExist must be true, otherwise a missing/wrong quest id can be treated as success."
                }
                if ($problem) { $problems += $problem }

                $entries += [pscustomobject]@{
                    Group = $groupName
                    Workflow = $workflow['Name']
                    Id = $id
                    Memo = $memo
                    LiveTitle = $liveTitle
                    Status = $status
                    FailIfNotExist = [bool]$selector['FailIfNotExist']
                }
            }
        }
    }

    $reports += [pscustomobject]@{
        Path = $resolvedPath
        ProblemCount = @($problems).Count
        Problems = @($problems)
        Entries = @($entries)
    }
}

$reports | ConvertTo-KcpsJsonOutput -Depth 20
