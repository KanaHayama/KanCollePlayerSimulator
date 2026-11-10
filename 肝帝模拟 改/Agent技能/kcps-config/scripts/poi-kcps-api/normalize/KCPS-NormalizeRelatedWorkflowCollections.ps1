#requires -Version 7.0

param(
    [Parameter(Mandatory = $true)]
    [string[]]$Path,

    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\KCPS-Common.ps1"

function Get-KcpsInputFiles {
    param([string]$InputPath)

    $resolved = Resolve-Path -LiteralPath $InputPath
    $item = Get-Item -LiteralPath $resolved.Path
    if ($item.PSIsContainer) {
        return @(Get-ChildItem -LiteralPath $item.FullName -File -Filter '*.conf.json' | Where-Object { Test-KcpsConfigScanPath -Path $_.FullName -ScanRoot $item.FullName })
    }
    return @($item)
}

function Get-WorkflowName {
    param([object]$Workflow)

    if (($Workflow -is [System.Collections.IDictionary]) -and (Test-MapKey -Map $Workflow -Key 'Name')) {
        return [string]$Workflow['Name']
    }
    return ''
}

$files = @()
foreach ($pathValue in $Path) {
    $files += @(Get-KcpsInputFiles -InputPath $pathValue)
}
$files = @($files | Sort-Object FullName -Unique)

$report = @()
foreach ($file in $files) {
    $config = Read-KcpsJson -Path $file.FullName
    $problems = @()

    function Find-CollectionShapeProblems {
        param(
            [object]$Node,
            [string]$ConfigName,
            [string]$WorkflowName,
            [string]$Path
        )

        $found = @()
        if ($Node -is [System.Collections.IDictionary]) {
            $currentWorkflowName = $WorkflowName
            if (Test-MapKey -Map $Node -Key 'Name') {
                $currentWorkflowName = Get-WorkflowName -Workflow $Node
            }
            foreach ($key in @($Node.Keys)) {
                $value = $Node[$key]
                $childPath = if ($Path) { "$Path.$key" } else { [string]$key }
                if (($script:KcpsJsonCollectionKeys -contains [string]$key) -and $null -ne $value -and -not (Test-KcpsArrayLike -Value $value)) {
                    $found += [pscustomobject]@{
                        Config = $ConfigName
                        Workflow = $currentWorkflowName
                        Key = $key
                        Path = $childPath
                        Shape = $value.GetType().FullName
                    }
                }
                $found += Find-CollectionShapeProblems -Node $value -ConfigName $ConfigName -WorkflowName $currentWorkflowName -Path $childPath
            }
        } elseif (Test-KcpsArrayLike -Value $Node) {
            $i = 0
            foreach ($item in @($Node)) {
                $found += Find-CollectionShapeProblems -Node $item -ConfigName $ConfigName -WorkflowName $WorkflowName -Path "$Path[$i]"
                $i++
            }
        }
        $found
    }

    foreach ($group in Get-KcpsGroups -Config $config) {
        $problems += Find-CollectionShapeProblems -Node $group -ConfigName ([string]$group['Name']) -WorkflowName '' -Path ''
    }

    if ($problems.Count -gt 0 -and -not $CheckOnly) {
        Write-KcpsJson -Value $config | Set-Content -LiteralPath $file.FullName -Encoding UTF8
    }

    $report += [pscustomobject]@{
        File = $file.FullName
        CheckOnly = [bool]$CheckOnly
        WouldFix = $problems.Count
        Fixed = [bool]($problems.Count -gt 0 -and -not $CheckOnly)
        Problems = @($problems)
    }
}

$report | ConvertTo-Json -Depth 20
