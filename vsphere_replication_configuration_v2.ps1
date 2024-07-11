<#
.INPUTS 
1. vsrAppliance [PSCustomObject]@{
    ApplianceAddress = 'IP.ADDR'
    ApplianceUser = 'AdministratorUser'
    AppliancePass    = 'SamplePassword'

2. vcenterAppliance [PSCustomObject]@{
    ApplianceAddress = 'IP.ADDR'
    ApplianceUser = 'AdministratorUser'
    AppliancePass    = 'SamplePassword'
}

#>
param(
    [PSCustomObject]
    $vsrAppliance,
    [PSCustomObject]
    $vcenterAppliance
  )


$SiteName = Read-Host "Enter vSphere Replication site name"


<#
Retrieves the SSL thumbprint for a given Platform Services Controller (PSC) via a given vSphere Replication appliance
#>
function Get-SSL-Thumbprint {
    param(
        [String]$VCenterAddress,
        [String]$VRSApplianceAddress,
        [String]$port,
        [String]$SessionID
    )
    $ConfigParams = @{
        pscHost = $VCenterAddress
        pscPort = $port
    } | ConvertTo-Json

    $URI = "https://" + $VRSApplianceAddress + ":5480/configure/requestHandlers/probeSsl"
    $Response = Invoke-WebRequest -SkipCertificateCheck -UseBasicParsing -Uri $URI `
        -Method "POST" `
        -Headers @{
        "dr.config.service.sessionid" = $SessionID
    } `
        -ContentType "application/json" `
        -Body $ConfigParams
    $Response = $Response | ConvertFrom-Json
    return $Response.data.thumbprint
}

<#
Login and retrieves a sessionID for a given vSphere replication server
#>
function Get-VrsSessionId {
    param(
        [String]$ApplianceUser,
        [String]$AppliancePass,
        [String]$ApplianceAddress
    )
    $ApplianceOnline = $false
    do {
        try {
            $URI = "https://" + $ApplianceAddress + ":5480/configure/requestHandlers/login"
            $response = Invoke-WebRequest -SkipCertificateCheck -UseBasicParsing -Uri $URI `
                -Method "POST" `
                -ContentType "application/json" `
                -Body "{`"username`":`"$ApplianceUser`",`"password`":`"$AppliancePass`"}" | ConvertFrom-Json
            
            $Session = $response.data.sessionId
            $ApplianceOnline = $true
        }
        catch {
            Write-Host("Waiting for [$ApplianceAddress] to come online") -ForegroundColor Green
            Start-Sleep(10)
        }
    } until (
        $ApplianceOnline
    )
    return $Session
}


<#
Retrieves a vCenter instance ID for a given vCenter appliance
#>
function Get-VCInstanceId {
    param(
        [String]$SessionID,
        [String]$Thumbprint,
        [String]$VCHost,
        [String]$ApplianceAddress
    )

    $ConfigParams = @{
        pscHost    = $VCHost
        pscPort    = 443
        thumbprint = $Thumbprint
    } | ConvertTo-Json
    $URI = "https://" + $ApplianceAddress + ":5480/configure/requestHandlers/listVcServices"
    ## Configure the VRS appliance to the local vCenter Server
    $Response = Invoke-RestMethod -SkipCertificateCheck -UseBasicParsing -Uri $URI `
        -Method "POST" `
        -Headers @{
        "dr.config.service.sessionid" = $SessionID
    } `
        -ContentType "application/json" `
        -Body $ConfigParams
    $VCInstanceId = $Response.data.serviceId
    return $VCInstanceId
}


<#
Configures a given vSphere replication appliance to a given vCenter
#>

function Connect-VrServertoVCenter {
    $ConfigParams = @{
        connection    = @{
            pscHost      = $PscHost
            pscPort      = 443
            thumbprint   = $Thumbprint
            vcInstanceId = $VCInstanceId
            vcThumbprint = $VCThumbprint
        }
        adminUser     = $vcenterAppliance.ApplianceUser
        adminPassword = $vcenterAppliance.AppliancePass
        siteName      = $SiteName
        adminEmail    = $vcenterAppliance.ApplianceUser
        hostName      = $vcenterAppliance.ApplianceAddress
        extensionKey  = $ExtenionKey
    } | ConvertTo-Json
    $vsrAddr = $vsrAppliance.ApplianceAddress
    Write-Host("Configuring vSphere replication to vCenter on: [$vsrAddr]") -ForegroundColor Green
    $URI = "https://" + $vsrAddr + ":5480/configure/requestHandlers/configureAppliance"
    ## Configure the VRS appliance to the local vCenter Server
    Invoke-RestMethod -SkipCertificateCheck -UseBasicParsing -Uri $URI `
        -Method "POST" `
        -Headers @{
        "dr.config.service.sessionid" = $Session
    } `
        -ContentType "application/json" `
        -Body $ConfigParams
    
    $vrServerReady = $false
    Write-Host("Configuring vSphere Replication. Please wait...") -ForegroundColor Green
    do {
        try {
            ## Try and connect to the configured appliance, if it is not yet ready then it will throw an exception and retry
            Connect-VrServer -Server $vcenterAppliance.ApplianceAddress -User $vcenterAppliance.ApplianceUser -Password $vcenterAppliance.AppliancePass
            $vrServerReady = $true
        }
        catch {
            Start-Sleep(5)
        }
    } until (
        $vrServerReady
    )

}

$Session = Get-VrsSessionId -ApplianceUser $vsrAppliance.ApplianceUser -AppliancePass $vsrAppliance.AppliancePass -ApplianceAddress $vsrAppliance.ApplianceAddress
$PscHost = $vcenterAppliance.ApplianceAddress
$Thumbprint = Get-SSL-Thumbprint -VCenterAddress $vcenterAppliance.ApplianceAddress -VRSApplianceAddress $vsrAppliance.ApplianceAddress -port 443 -SessionID $Session
$VCInstanceId = Get-VCInstanceId -ApplianceAddress $vsrAppliance.ApplianceAddress -SessionID $Session -Thumbprint $Thumbprint -VCHost $vcenterAppliance.ApplianceAddress
$VCThumbprint = Get-SSL-Thumbprint -VCenterAddress $vcenterAppliance.ApplianceAddress -VRSApplianceAddress $vsrAppliance.ApplianceAddress -port 443 -SessionID $Session
$ExtenionKey = "com.vmware.vcHms"


Connect-VrServertoVCenter | Out-Null