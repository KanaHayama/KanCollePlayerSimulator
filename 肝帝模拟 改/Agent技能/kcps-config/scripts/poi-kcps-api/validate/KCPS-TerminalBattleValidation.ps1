function Get-KcpsTerminalBattleNodes {
    param($RouteSpec)
    if ($null -eq $RouteSpec -or [int]$RouteSpec['Sea'] -ne 0) { return }
    $route = @($RouteSpec['Route'])
    if ($route.Count -eq 0) { return }
    # 路线终点不是Boss时，显式结束本次出击。
    @($RouteSpec['Nodes'] | Where-Object {
        [string]$_['Letter'] -eq [string]$route[-1] -and
        [string]$_['Kind'] -in @('surface', 'submarine', 'airraid', 'airbattle')
    })
}

function Get-KcpsTerminalBattleProblems {
    param($RouteSpec, $Sortie)
    foreach ($node in @(Get-KcpsTerminalBattleNodes -RouteSpec $RouteSpec)) {
        if ($node['ExpectedAdvance'] -ne 2) {
            "路线终点 $($node['Letter']) 的规格必须明确 ExpectedAdvance=2（撤退），不能用错误规格验证错误配置。"
        }
        $matches = @($Sortie['Strategies'] | Where-Object {
            [int]$_['Condition']['Type'] -eq 1 -and
            [int]$_['Condition']['Value'] -eq [int]$node['Value']
        })
        if ($matches.Count -ne 1 -or $matches[0]['Strategy']['DefaultAdvance'] -ne 2) {
            "路线终点 $($node['Letter']) 必须有唯一的战后撤退策略（DefaultAdvance=2）；总控停止条件不能替代回港动作。"
        }
    }
}
