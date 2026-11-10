#requires -Version 7.0

function Get-KcpsResupplyCost {
    param([ValidateRange(0, 10000)][int]$Missing, [bool]$Married)
    if ($Missing -eq 0) { return 0 }
    if (-not $Married) { return $Missing }
    # 补给时打折，单项非零消耗最低为1。
    return [int][math]::Max(1, [math]::Floor($Missing * 0.85))
}

function Get-KcpsDefensePlaneAirPower {
    param(
        [System.Collections.IDictionary]$Master,
        [ValidateRange(0, 99)][int]$AircraftCount = 18,
        [double]$Improvement = 0,
        [double]$ProficiencyBonus = 0
    )
    $type = [int]$Master['api_type'][2]
    $count = if ($type -in @(9, 10, 41, 49)) { [math]::Min(4, $AircraftCount) } else { $AircraftCount }
    if ($count -eq 0) { return 0 }
    $air = [double]$Master['api_tyku'] + $Improvement
    # 只有陆战、局战把回避和命中字段解释为迎击、对爆。
    if ($type -in @(48, 43)) { $air += [int]$Master['api_houk'] + 2 * [int]$Master['api_houm'] }
    return [int][math]::Floor($air * [math]::Sqrt($count) + $ProficiencyBonus)
}
