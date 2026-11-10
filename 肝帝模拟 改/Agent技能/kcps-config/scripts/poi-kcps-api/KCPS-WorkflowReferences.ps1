function Get-KcpsSortieWorkflowReferenceProblems {
    param([object[]]$Workflows)

    foreach ($controller in @($Workflows | Where-Object { Test-KcpsWorkflowType $_ 'RelationalSortieWorkflow' })) {
        $reference = $controller['SortieWorkflow']
        $problems = @()
        # 先检查载入格式，再解析关联目标。
        if ($reference -isnot [hashtable]) {
            $problems += 'SortieWorkflow 必须是关联对象，不能是裸GUID字符串、数组或空值；错误格式会导致总控载入失败。'
        } else {
            $id = [guid]::Empty
            if ($reference['Guid'] -isnot [string] -or
                -not [guid]::TryParse($reference['Guid'], [ref]$id) -or $id -eq [guid]::Empty) {
                $problems += 'SortieWorkflow.Guid 必须是有效且非空的GUID字符串。'
            } else {
                $targets = @($Workflows | Where-Object { [string]$_['Guid'] -eq [string]$id })
                if ($targets.Count -ne 1) {
                    $problems += 'SortieWorkflow 必须唯一指向同一配置内的出击执行单元。'
                } elseif (-not (Test-KcpsWorkflowType $targets[0] 'SimpleSortieWorkflow')) {
                    $problems += 'SortieWorkflow 的目标必须是 SimpleSortieWorkflow 出击执行单元。'
                }
            }
            # 缺省布尔值沿用原生默认值：启用、不忽略失败。
            foreach ($key in 'Enabled','IgnoreTriggerFailure') {
                if ($reference.ContainsKey($key) -and $reference[$key] -isnot [bool]) {
                    $problems += "SortieWorkflow.$key 必须是JSON布尔值。"
                }
            }
            if ($reference['Enabled'] -is [bool] -and -not $reference['Enabled']) {
                $problems += 'SortieWorkflow.Enabled 不得关闭，否则总控无法执行出击。'
            }
        }
        foreach ($problem in $problems) {
            [pscustomobject]@{Workflow=$controller['Name'];Key='SortieWorkflow';Problem=$problem}
        }
    }
}
