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

$Pool_Fee = 0.5

$Pool_Request = [PSCustomObject]@{}
$PoolCoins_Request = [PSCustomObject]@{}

try {
    $PoolCoins_Request = Invoke-RestMethodAsync "http://api.zergpool.com:8080/api/currencies" -retry 5 -retrywait 750 -tag $Name
}
catch {
    if ($Error.Count){$Error.RemoveAt(0)}
    Write-Log -Level Warn "Pool API ($Name) has failed. "
    return
}

if (($PoolCoins_Request | Get-Member -MemberType NoteProperty -ErrorAction Ignore | Measure-Object Name).Count -le 1) {
    Write-Log -Level Warn "Pool API ($Name) returned nothing. "
    return
}

try {
    $Pool_Request = Invoke-RestMethodAsync "http://api.zergpool.com:8080/api/status" -retry 5 -retrywait 500 -tag $Name
}
catch {
    if ($Error.Count){$Error.RemoveAt(0)}
    Write-Log -Level Warn "Pool status API ($Name) has failed. "
}

[hashtable]$Pool_Algorithms = @{}
[hashtable]$Pool_RegionsTable = @{}

$Pool_Regions = @("us")
$Pool_Regions | Foreach-Object {$Pool_RegionsTable.$_ = Get-Region $_}
$Pool_Currencies = @("BTC", "DASH", "LTC") + @($Wallets.PSObject.Properties.Name | Select-Object) | Select-Object -Unique | Where-Object {$Wallets.$_ -or $InfoOnly}
$Pool_PoolFee = 0.5

$PoolCoins_Request | Get-Member -MemberType NoteProperty -ErrorAction Ignore | Select-Object -ExpandProperty Name | Where-Object {$PoolCoins_Request.$_.hashrate -gt 0 -or $InfoOnly} | ForEach-Object {
    $Pool_CoinSymbol = $_

    $Pool_Host = "$($PoolCoins_Request.$Pool_CoinSymbol.algo).mine.zergpool.com"
    $Pool_Port = $PoolCoins_Request.$Pool_CoinSymbol.port
    $Pool_Algorithm = $PoolCoins_Request.$Pool_CoinSymbol.algo
    if (-not $Pool_Algorithms.ContainsKey($Pool_Algorithm)) {$Pool_Algorithms.$Pool_Algorithm = Get-Algorithm $Pool_Algorithm}
    $Pool_Algorithm_Norm = $Pool_Algorithms.$Pool_Algorithm
    $Pool_Coin = $PoolCoins_Request.$Pool_CoinSymbol.name
    $Pool_PoolFee = if ($Pool_Request.$Pool_Algorithm) {$Pool_Request.$Pool_Algorithm.fees} else {$Pool_Fee}
    $Pool_Currency = if ($PoolCoins_Request.$Pool_CoinSymbol.symbol) {$PoolCoins_Request.$Pool_CoinSymbol.symbol} else {$Pool_CoinSymbol}
    $Pool_User = $Wallets.$Pool_Currency

    if ($Pool_Algorithm_Norm -ne "Equihash" -and $Pool_Algorithm_Norm -like "Equihash*") {$Pool_Algorithm_All = @($Pool_Algorithm_Norm,"$Pool_Algorithm_Norm-$Pool_Currency")} else {$Pool_Algorithm_All = @($Pool_Algorithm_Norm)}

    if ($PoolCoins_Request.$Pool_CoinSymbol.mbtc_mh_factor) {
        $Pool_Factor = [Double]$PoolCoins_Request.$Pool_CoinSymbol.mbtc_mh_factor
    } else {
        $Pool_Factor = [Double]$(Switch ($_) {
            "aergo" {1}
            "allium" {1}
            "argon2d-dyn" {1}
            "balloon" {0.001}
            "bitcore" {1}
            "blake2s" {1000}
            "c11" {1}
            "equihash" {0.001}
            "equihash144" {0.001}
            "equihash192" {0.001}
            "equihash96" {1}
            "hex" {1000}
            "hmq1725" {1}
            "keccak" {1000}
            "keccakc" {1000}
            "lbry" {1000}
            "lyra2v2" {1}
            "lyra2z" {1}
            "m7m" {1}
            "myr-gr" {1000}
            "neoscrypt" {1}
            "nist5" {1000}
            "phi" {1}
            "phi2" {1}
            "polytimos" {1}
            "quark" {1000}
            "qubit" {1000}
            "scrypt" {1000}
            "sha256" {1000000000}
            "skein" {1000}
            "skunk" {1}
            "sonoa" {1}
            "tribus" {1}
            "x11" {1000}
            "x11evo" {1}
            "x13" {1000}
            "x16r" {1}
            "x16s" {1}
            "x17" {1}
            "xevan" {1}
            "yescrypt" {0.001}
            "yescryptR16" {0.001}
            "yespower" {0.001}
        })
    }
    if ($Pool_Factor -le 0) {
        Write-Log -Level Info "Unable to determine divisor for $Pool_Coin using $Pool_Algorithm_Norm algorithm"
        return
    }

    $Divisor = 1e9 * $Pool_Factor

    $Pool_TSL = $PoolCoins_Request.$Pool_CoinSymbol.timesincelast

    if (-not $InfoOnly) {
        $Stat = Set-Stat -Name "$($Name)_$($Pool_CoinSymbol)_Profit" -Value ([Double]$PoolCoins_Request.$Pool_CoinSymbol.estimate / $Divisor) -Duration $StatSpan -ChangeDetection $true
        $StatHSR = Set-Stat -Name "$($Name)_$($Pool_CoinSymbol)_HSR" -Value ([Int64]$PoolCoins_Request.$Pool_CoinSymbol.hashrate) -Duration $StatSpan -ChangeDetection $false
        $StatBLK = Set-Stat -Name "$($Name)_$($Pool_CoinSymbol)_BLK" -Value ([Int64]$PoolCoins_Request.$Pool_CoinSymbol."24h_blocks") -Duration $StatSpan -ChangeDetection $false
    }

    foreach($Pool_Region in $Pool_Regions) {
        foreach($Pool_Algorithm_Norm in $Pool_Algorithm_All) {
            if ($Pool_User -or $InfoOnly) {
                #Option 2
                [PSCustomObject]@{
                    Algorithm     = $Pool_Algorithm_Norm
                    CoinName      = $Pool_Coin
                    CoinSymbol    = $Pool_CoinSymbol
                    Currency      = $Pool_Currency
                    Price         = $Stat.Hour #instead of .Live
                    StablePrice   = $Stat.Week
                    MarginOfError = $Stat.Week_Fluctuation
                    Protocol      = "stratum+tcp"
                    Host          = if ($Pool_Region -eq "us") {$Pool_Host} else {"$Pool_Region.$Pool_Host"}
                    Port          = $Pool_Port
                    User          = $Pool_User
                    Pass          = "$Worker,c=$Pool_Currency,mc=$Pool_Currency"
                    Region        = $Pool_RegionsTable.$Pool_Region
                    SSL           = $false
                    Updated       = $Stat.Updated
                    PoolFee       = $Pool_PoolFee
                    Hashrate      = $StatHSR.Hour
                    BLK           = $StatBLK.Hour
                    TSL           = $Pool_TSL
                }
            }
            if (($PoolCoins_Request.$Pool_Currency.noautotrade -eq 0 -and -not $Pool_User) -or $InfoOnly) {
                foreach($Pool_ExCurrency in $Pool_Currencies) {
                    #Option 3
                    [PSCustomObject]@{
                        Algorithm     = $Pool_Algorithm_Norm
                        CoinName      = $Pool_Coin
                        CoinSymbol    = $Pool_CoinSymbol
                        Currency      = $Pool_ExCurrency
                        Price         = $Stat.Hour #instead of .Live
                        StablePrice   = $Stat.Week
                        MarginOfError = $Stat.Week_Fluctuation
                        Protocol      = "stratum+tcp"
                        Host          = if ($Pool_Region -eq "us") {$Pool_Host}else {"$Pool_Region.$Pool_Host"}
                        Port          = $Pool_Port
                        User          = $Wallets.$Pool_ExCurrency
                        Pass          = "$Worker,c=$Pool_ExCurrency,mc=$Pool_Currency"
                        Region        = $Pool_RegionsTable.$Pool_Region
                        SSL           = $false
                        Updated       = $Stat.Updated
                        PoolFee       = $Pool_PoolFee
                        Hashrate      = $StatHSR.Hour
                        BLK           = $StatBLK.Hour
                        TSL           = $Pool_TSL
                    }
                }
            }
        }
    }
}
