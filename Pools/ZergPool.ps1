﻿using module ..\Include.psm1

param(
    [PSCustomObject]$Wallets,
    [alias("WorkerName")]
    [String]$Worker, 
    [TimeSpan]$StatSpan,
    [String]$DataWindow = "estimate_current",
    [Bool]$InfoOnly = $false
)

$Name = Get-Item $MyInvocation.MyCommand.Path | Select-Object -ExpandProperty BaseName

$Pool_Request = [PSCustomObject]@{}
$PoolCoins_Request = [PSCustomObject]@{}

try {
    $Pool_Request = Invoke-RestMethodAsync "http://api.zergpool.com:8080/api/status" -retry 5 -retrywait 500 -tag $Name
}
catch {
    if ($Error.Count){$Error.RemoveAt(0)}
    Write-Log -Level Warn "Pool API ($Name) has failed. "
    return
}

if (($Pool_Request | Get-Member -MemberType NoteProperty -ErrorAction Ignore | Measure-Object Name).Count -le 1) {
    Write-Log -Level Warn "Pool API ($Name) returned nothing. "
    return
}

try {
    $PoolCoins_Request = Invoke-RestMethodAsync "http://api.zergpool.com:8080/api/currencies" -retry 5 -retrywait 750 -tag $Name
}
catch {
    if ($Error.Count){$Error.RemoveAt(0)}
    Write-Log -Level Warn "Pool currencies API ($Name) has failed. "
}

[hashtable]$Pool_Algorithms = @{}
[hashtable]$Pool_Coins = @{}
[hashtable]$Pool_RegionsTable = @{}

$Pool_Regions = @("us")
$Pool_Regions | Foreach-Object {$Pool_RegionsTable.$_ = Get-Region $_}
$Pool_Currencies = @("BTC", "DASH", "LTC") + @($Wallets.PSObject.Properties.Name | Select-Object) + @($PoolCoins_Request | Get-Member -MemberType NoteProperty -ErrorAction Ignore | Select-Object -ExpandProperty Name | Foreach-Object {if ($PoolCoins_Request.$_.Symbol) {$PoolCoins_Request.$_.Symbol} else {$_}}) | Select-Object -Unique | Where-Object {$Wallets.$_ -or $InfoOnly}
if ($PoolCoins_Request) {
    $PoolCoins_Algorithms = @($Pool_Request.PSObject.Properties.Value | Where-Object coins -eq 1 | Select-Object -ExpandProperty name -Unique)
    if ($PoolCoins_Algorithms.Count) {foreach($p in $PoolCoins_Request.PSObject.Properties.Name) {if ($PoolCoins_Algorithms -contains $PoolCoins_Request.$p.algo) {$Pool_Coins[$PoolCoins_Request.$p.algo] = [hashtable]@{Name = $PoolCoins_Request.$p.name; Symbol = $p -replace '-.+$'}}}}
}
$Pool_PoolFee = 0.5

$Pool_Request | Get-Member -MemberType NoteProperty -ErrorAction Ignore | Select-Object -ExpandProperty Name | Where-Object {($Pool_Request.$_.hashrate -gt 0 -and [Double]$Pool_Request.$_.estimate_current  -gt 0) -or $InfoOnly} |ForEach-Object {
    $Pool_Host = "$($Pool_Request.$_.name).mine.zergpool.com"
    $Pool_Port = $Pool_Request.$_.port
    $Pool_Algorithm = $Pool_Request.$_.name
    if (-not $Pool_Algorithms.ContainsKey($Pool_Algorithm)) {$Pool_Algorithms.$Pool_Algorithm = Get-Algorithm $Pool_Algorithm}
    $Pool_Algorithm_Norm = $Pool_Algorithms.$Pool_Algorithm
    $Pool_Coin = $Pool_Coins.$Pool_Algorithm.Name
    $Pool_Symbol = $Pool_Coins.$Pool_Algorithm.Symbol
    $Pool_PoolFee = [Double]$Pool_Request.$_.fees
    if ($Pool_Coin -and -not $Pool_Symbol) {$Pool_Symbol = Get-CoinSymbol $Pool_Coin}

    if ($Pool_Symbol -and $Pool_Algorithm_Norm -ne "Equihash" -and $Pool_Algorithm_Norm -like "Equihash*") {$Pool_Algorithm_All = @($Pool_Algorithm_Norm,"$Pool_Algorithm_Norm-$Pool_Symbol")} else {$Pool_Algorithm_All = @($Pool_Algorithm_Norm)}

    $Pool_Factor = [double]$Pool_Request.$_.mbtc_mh_factor
    if ($Pool_Factor -le 0) {
        Write-Log -Level Info "$($Name): Unable to determine divisor for algorithm $Pool_Algorithm. "
        return
    }

    $Pool_TSL = ($PoolCoins_Request.PSObject.Properties.Value | Where-Object algo -eq $Pool_Algorithm | Measure-Object timesincelast -Minimum).Minimum
    $Pool_BLK = ($PoolCoins_Request.PSObject.Properties.Value | Where-Object algo -eq $Pool_Algorithm | Measure-Object "24h_blocks" -Maximum).Maximum

    if (-not $InfoOnly) {
        if (-not (Test-Path "Stats\Pools\$($Name)_$($Pool_Algorithm_Norm)_Profit.txt")) {$Stat = Set-Stat -Name "$($Name)_$($Pool_Algorithm_Norm)_Profit" -Value (Get-YiiMPValue $Pool_Request.$_ -DataWindow "actual_last24h" -Factor $Pool_Factor) -Duration (New-TimeSpan -Days 1)}
        else {$Stat = Set-Stat -Name "$($Name)_$($Pool_Algorithm_Norm)_Profit" -Value (Get-YiiMPValue $Pool_Request.$_ -DataWindow $DataWindow -Factor $Pool_Factor) -Duration $StatSpan -ChangeDetection $true}
        $StatHSR = Set-Stat -Name "$($Name)_$($Pool_Algorithm_Norm)_HSR" -Value ([Int64]$Pool_Request.$_.hashrate) -Duration $StatSpan -ChangeDetection $false
        if ($PoolCoins_Request) {$StatBLK = Set-Stat -Name "$($Name)_$($Pool_Algorithm_Norm)_BLK" -Value $Pool_BLK -Duration $StatSpan -ChangeDetection $false}
    }

    foreach($Pool_Region in $Pool_Regions) {
        $Pool_Region_Host = if ($Pool_Region -eq "us") {$Pool_Host} else {"$Pool_Region.$Pool_Host"}
        foreach($Pool_Currency in $Pool_Currencies) {
            foreach($Pool_Algorithm_Norm in $Pool_Algorithm_All) {
                #Option 1
                [PSCustomObject]@{
                    Algorithm     = $Pool_Algorithm_Norm
                    CoinName      = $Pool_Coin
                    CoinSymbol    = $Pool_Symbol
                    Currency      = $Pool_Currency
                    Price         = $Stat.Hour #instead of .Live
                    StablePrice   = $Stat.Week
                    MarginOfError = $Stat.Week_Fluctuation
                    Protocol      = "stratum+tcp"
                    Host          = $Pool_Region_Host
                    Port          = $Pool_Port
                    User          = $Wallets.$Pool_Currency
                    Pass          = "$Worker,c=$Pool_Currency"
                    Region        = $Pool_RegionsTable.$Pool_Region
                    SSL           = $false
                    Updated       = $Stat.Updated
                    PoolFee       = $Pool_PoolFee
                    DataWindow    = $DataWindow
                    Hashrate      = $StatHSR.Hour
                    BLK           = $StatBLK.Hour
                    TSL           = $Pool_TSL
                }
            }
        }
    }
}
