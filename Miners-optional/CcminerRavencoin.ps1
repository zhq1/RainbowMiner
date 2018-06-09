﻿using module ..\Include.psm1

$Path = ".\Bin\NVIDIA-x16r-Ravencoin\ccminer.exe"
$Uri = "https://github.com/RainbowMiner/miner-binaries/releases/download/v3.0-ravencoinminer/ccminerRavenx32.zip"

$Devices = $Devices.NVIDIA
if (-not $Devices -or $Config.InfoOnly) {return} # No NVIDIA present in system

$Commands = [PSCustomObject]@{
    "x16r"  = " -N 10 --donate 0" #X16R RavenCoin
    #"x16s"  = "" #X16S PigeonCoin
}

$Default_Profile = 2
$Profiles = [PSCustomObject]@{
    "x16r" = 4
    "x16s" = 4
}

$Default_Tolerance = 0.1
$Tolerances = [PSCustomObject]@{
    "x16r" = 0.5
}

$Default_HashRates_Duration = "Week"
$HashRates_Durations = [PSCustomObject]@{
    "x16r" = "Day"
}

$Name = Get-Item $MyInvocation.MyCommand.Path | Select-Object -ExpandProperty BaseName

$DeviceIDsAll = Get-GPUIDs $Devices -join ','

$Commands | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name | Where-Object {$Pools.(Get-Algorithm $_).Protocol -eq "stratum+tcp" <#temp fix#>} | ForEach-Object {

    $Algorithm_Norm = Get-Algorithm $_
    $HashRates_Duration = if ( $HashRates_Durations.$_ ) { $HashRates_Durations.$_ } else { $Default_HashRates_Duration }

    [PSCustomObject]@{
        DeviceName = $Devices.Name
        Path = $Path
        Arguments = "-r 0 -d $($DeviceIDsAll) -a $_ -o $($Pools.$Algorithm_Norm.Protocol)://$($Pools.$Algorithm_Norm.Host):$($Pools.$Algorithm_Norm.Port) -u $($Pools.$Algorithm_Norm.User) -p $($Pools.$Algorithm_Norm.Pass)$($Commands.$_)"
        HashRates = [PSCustomObject]@{$Algorithm_Norm = $Stats."$($Name)_$($Algorithm_Norm)_HashRate".$HashRates_Duration}
        API = "Ccminer"
        Port = 4068
        URI = $Uri
        MSIAprofile = if ( $Profiles.$_ ) { $Profiles.$_ } else { $Default_Profile }
        FaultTolerance = if ( $Tolerances.$_ ) { $Tolerances.$_ } else { $Default_Tolerance }
        DevFee = 1.0
    }
}