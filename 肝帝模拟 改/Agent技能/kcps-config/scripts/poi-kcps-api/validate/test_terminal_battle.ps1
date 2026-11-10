$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\KCPS-TerminalBattleValidation.ps1"
$r = @{Sea=0; Route=@('1','A','Y2'); Nodes=@(
    @{Letter='A'; Value=1; Kind='surface'; ExpectedAdvance=1},
    @{Letter='Y2'; Value=64; Kind='surface'; ExpectedAdvance=0})}
$s = @{Strategies=@(@{Condition=@{Type=1;Value=64};Strategy=@{DefaultAdvance=0;Memo='目标水面战'}})}
function Assert-Count($Expected) {
    $actual = @(Get-KcpsTerminalBattleProblems $r $s).Count
    if ($actual -ne $Expected) { throw "Expected $Expected problems, got $actual" }
}
Assert-Count 2
$r.Nodes[1].ExpectedAdvance=2
Assert-Count 1
$s.Strategies[0].Strategy.DefaultAdvance=2
Assert-Count 0
$s.Strategies[0].Strategy.DefaultAdvance=1
Assert-Count 1
$s.Strategies=@()
Assert-Count 1
$r.Nodes[1].Kind='boss'
Assert-Count 0
$r.Nodes[1].Kind='submarine'
Assert-Count 1
$r.Sea=1
Assert-Count 0
'8 terminal battle tests passed'
