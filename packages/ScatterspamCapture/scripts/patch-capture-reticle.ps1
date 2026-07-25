param(
    [Parameter(Mandatory = $true)]
    [string]$InputJson,

    [Parameter(Mandatory = $true)]
    [string]$OutputJson
)

$ErrorActionPreference = "Stop"

function Get-PathLeaf {
    param($Node)
    if ($null -eq $Node -or $null -eq $Node.Variable -or
        $null -eq $Node.Variable.New -or $null -eq $Node.Variable.New.Path) {
        return $null
    }
    return @($Node.Variable.New.Path)[-1]
}

function Get-ImportName {
    param($Asset, $Call)
    $index = [int]$Call.StackNode
    if ($index -ge 0) {
        return $null
    }
    return $Asset.Imports[-$index - 1].ObjectName
}

function Find-Nodes {
    param($Node, [scriptblock]$Predicate)
    $found = @()
    if ($null -eq $Node) {
        return $found
    }
    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        if (& $Predicate $Node) {
            $found += $Node
        }
        foreach ($property in $Node.PSObject.Properties) {
            $found += Find-Nodes $property.Value $Predicate
        }
    }
    elseif ($Node -is [System.Collections.IEnumerable] -and
            $Node -isnot [string]) {
        foreach ($item in $Node) {
            $found += Find-Nodes $item $Predicate
        }
    }
    return $found
}

function Copy-Node {
    param($Node)
    return ($Node | ConvertTo-Json -Depth 100 -Compress | ConvertFrom-Json)
}

$asset = Get-Content -Raw -LiteralPath $InputJson | ConvertFrom-Json
$function = $asset.Exports |
    Where-Object ObjectName -eq "Set Display Capture Rate Force"
if ($null -eq $function) {
    throw "Set Display Capture Rate Force was not found."
}

$setTextTemplate = Find-Nodes $function.ScriptBytecode {
    param($node)
    $node.'$type' -like "*EX_Context*" -and
    $node.ContextExpression.VirtualFunctionName -eq "SetText" -and
    (Get-PathLeaf $node.ObjectExpression) -eq "BP_PalTextBlock_C_5"
} | Select-Object -First 1

$multiplyTemplate = Find-Nodes $function.ScriptBytecode {
    param($node)
    $node.'$type' -like "*EX_CallMath*" -and
    (Get-ImportName $asset $node) -eq "Multiply_DoubleDouble" -and
    (Get-PathLeaf @($node.Parameters)[0]) -eq "rate"
} | Select-Object -First 1

$roundTemplate = Find-Nodes $function.ScriptBytecode {
    param($node)
    $node.'$type' -like "*EX_CallMath*" -and
    (Get-ImportName $asset $node) -eq "Round"
} | Select-Object -First 1

$percentTemplate = Find-Nodes $function.ScriptBytecode {
    param($node)
    $node.'$type' -like "*EX_CallMath*" -and
    (Get-ImportName $asset $node) -eq "Percent_IntInt"
} | Select-Object -First 1

$convTemplate = Find-Nodes $function.ScriptBytecode {
    param($node)
    $node.'$type' -like "*EX_CallMath*" -and
    (Get-ImportName $asset $node) -eq "Conv_IntToText"
} | Select-Object -First 1

foreach ($required in @(
    $setTextTemplate,
    $multiplyTemplate,
    $roundTemplate,
    $percentTemplate,
    $convTemplate
)) {
    if ($null -eq $required) {
        throw "A required bytecode template was not found."
    }
}

# Build: Conv_IntToText(Round(rate * 1000) % 10). This directly drives the
# former percent-sign widget, which is restyled and positioned as digit three.
$multiply = Copy-Node $multiplyTemplate
$multiply.Parameters[1].Value = 1000.0

$round = Copy-Node $roundTemplate
$round.Parameters = [object[]]@($multiply)

$percent = Copy-Node $percentTemplate
$percent.Parameters[0] = $round
$percent.Parameters[1].Value = 10

$conv = Copy-Node $convTemplate
$conv.Parameters[0] = $percent

$setThirdDigit = Copy-Node $setTextTemplate
$setThirdDigit.ObjectExpression.Variable.New.Path[0] = "BP_PalTextBlock_C_6"
$setThirdDigit.ContextExpression.Parameters = [object[]]@($conv)

$returnIndex = -1
for ($index = 0; $index -lt $function.ScriptBytecode.Count; $index++) {
    if ($function.ScriptBytecode[$index].'$type' -like "*EX_Return*") {
        $returnIndex = $index
        break
    }
}
if ($returnIndex -lt 0) {
    throw "Function return instruction was not found."
}

$bytecode = [System.Collections.ArrayList]@($function.ScriptBytecode)
$bytecode.Insert($returnIndex, $setThirdDigit)
$function.ScriptBytecode = $bytecode.ToArray()

# The fourth item in the decimal canvas used to be the percent sign. Give it
# the same digit appearance as the second fractional digit.
$secondDigit = $asset.Exports[8]  # BP_PalTextBlock_C_5
$thirdDigit = $asset.Exports[9]   # BP_PalTextBlock_C_6
$thirdDigit.Data = $secondDigit.Data
$thirdDigit.Extras = $secondDigit.Extras

# Move the former percent-sign slot onto the decimal baseline at x=62.
$secondDigitSlot = $asset.Exports[76] # CanvasPanelSlot_9
$thirdDigitSlot = $asset.Exports[75]  # CanvasPanelSlot_10
$thirdDigitSlot.Data = Copy-Node $secondDigitSlot.Data
$content = $thirdDigitSlot.Data |
    Where-Object Name -eq "Content" |
    Select-Object -First 1
$content.Value = 10
$left = Find-Nodes $thirdDigitSlot.Data {
    param($node)
    $node.Name -eq "Left" -and $node.'$type' -like "*FloatPropertyData*"
} | Select-Object -First 1
$left.Value = 62.0

New-Item -ItemType Directory -Force `
    -Path (Split-Path -Parent $OutputJson) | Out-Null
$asset | ConvertTo-Json -Depth 100 -Compress |
    Set-Content -LiteralPath $OutputJson -Encoding UTF8

Write-Host "Patched third capture-rate decimal into $OutputJson"
