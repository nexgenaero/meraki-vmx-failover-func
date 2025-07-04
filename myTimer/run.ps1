#-------------------------------------------------------------------------
#
# High Availability (HA) Network Virtual Appliance (NVA) Failover Function
#
# This script provides a sample for monitoring HA NVA firewall status and performing
# failover and/or failback if needed. It has been updated to run in PowerShell 7.4 and
# use Az modules on Azure Functions v4.
#
# To configure this function app, the following items must be setup:
#
#   - Provision the pre-requisite Azure Resource Groups, Virtual Networks and Subnets, Network Virtual Appliances
#
#   - Create an Azure timer function app running PowerShell 7.4 (Functions v4)
#
#   - Set the Azure function app settings with credentials:
#     SP_PASSWORD, SP_USERNAME, TENANTID, SUBSCRIPTIONID, AZURECLOUD must be added
#     AZURECLOUD = "AzureCloud" or "AzureUSGovernment"
#
#   - Set Firewall VM names and Resource Group in the Azure function app settings:
#     FW1NAME, FW2NAME, FWMONITOR, FW1FQDN, FW1PORT, FW2FQDN, FW2PORT, FWRGNAME, FWTRIES, FWDELAY, FWUDRTAG must be added
#     FWMONITOR = "VMStatus" or "TCPPort" - If using "TCPPort", then also set FW1FQDN, FW2FQDN, FW1PORT and FW2PORT values
#
#   - Set Timer Schedule where positions represent: Seconds - Minutes - Hours - Day - Month - DayofWeek
#     Example:  "*/30 * * * * *" to run on multiples of 30 seconds
#     Example:  "0 */5 * * * *"  to run on multiples of 5 minutes on the 0-second mark
#
#-------------------------------------------------------------------------
#-------------------------------------------------------------------------
#
# High Availability (HA) Network Virtual Appliance (NVA) Failover Function
#
# This script provides a sample for monitoring HA NVA firewall status and performing
# failover and/or failback if needed. It has been updated to run in PowerShell 7.4 and
# use Az modules on Azure Functions v4.
#
# To configure this function app, the following items must be setup:
#
#   - Provision the pre-requisite Azure Resource Groups, Virtual Networks and Subnets, Network Virtual Appliances
#
#   - Create an Azure timer function app running PowerShell 7.4 (Functions v4)
#
#   - Set the Azure function app settings with credentials:
#     SP_PASSWORD, SP_USERNAME, TENANTID, SUBSCRIPTIONID, AZURECLOUD must be added
#     AZURECLOUD = "AzureCloud" or "AzureUSGovernment"
#
#   - Set Firewall VM names and Resource Group in the Azure function app settings:
#     FW1NAME, FW2NAME, FWMONITOR, FW1FQDN, FW1PORT, FW2FQDN, FW2PORT, FWRGNAME, FWTRIES, FWDELAY, FWUDRTAG must be added
#     FWMONITOR = "VMStatus" or "TCPPort" - If using "TCPPort", then also set FW1FQDN, FW2FQDN, FW1PORT and FW2PORT values
#
#   - Set Timer Schedule where positions represent: Seconds - Minutes - Hours - Day - Month - DayofWeek
#     Example:  "*/30 * * * * *" to run on multiples of 30 seconds
#     Example:  "0 */5 * * * *"  to run on multiples of 5 minutes on the 0-second mark
#
#-------------------------------------------------------------------------

param($myTimer, $TriggerMetadata)

Write-Output -InputObject "HA NVA timer trigger function executed at: $(Get-Date)"

#--------------------------------------------------------------------------  
# Set firewall monitoring variables here  
#--------------------------------------------------------------------------

$VMFW1Name = $env:FW1NAME      # Set the Name of the primary NVA firewall  
$VMFW2Name = $env:FW2NAME      # Set the Name of the secondary NVA firewall  
$FW1RGName = $env:FWRGNAME     # Set the ResourceGroup that contains FW1  
$FW2RGName = $env:FWRGNAME2    # Set the ResourceGroup that contains FW2  
$Monitor = $env:FWMONITOR      # "VMStatus" or "TCPPort" are valid values  

#--------------------------------------------------------------------------  
# The parameters below are required if using "TCPPort" mode for monitoring  
#--------------------------------------------------------------------------

$TCPFW1Server = $env:FW1FQDN   # Hostname of the site to be monitored via the primary NVA firewall if using "TCPPort"  
$TCPFW1Port = $env:FW1PORT     # TCP Port of the site to be monitored via the primary NVA firewall if using "TCPPort"  
$TCPFW2Server = $env:FW2FQDN   # Hostname of the site to be monitored via the secondary NVA firewall if using "TCPPort"  
$TCPFW2Port = $env:FW2PORT     # TCP Port of the site to be monitored via the secondary NVA firewall if using "TCPPort"  

#--------------------------------------------------------------------------  
# Set the failover and failback behavior for the firewalls  
#--------------------------------------------------------------------------

$FailOver = $True              # Enable fail-over to secondary NVA if primary drops  
$FailBack = $True              # Enable fail-back to primary if secondary drops  
$IntTries = $env:FWTRIES       # Number of firewall tests to try   
$IntSleep = $env:FWDELAY       # Delay in seconds between tries  

#--------------------------------------------------------------------------  
# Code blocks for supporting functions  
#--------------------------------------------------------------------------

Function Send-AlertMessage ($Message) {
  $MailServers = (Resolve-DnsName -Type MX -Name $env:FWMAILDOMAINMX).NameExchange
  $MailFrom = $env:FWMAILFROM
  $MailTo = $env:FWMAILTO

  try { Send-MailMessage -SmtpServer $MailServers[1] -From $MailFrom -To $MailTo -Subject $Message -Body $Message }
  catch { Send-MailMessage -SmtpServer $MailServers[2] -From $MailFrom -To $MailTo -Subject $Message -Body $Message }
}

Function Test-VMStatus ($VM, $FWResourceGroup) {
  $VMDetail = Get-AzVM -ResourceGroupName $FWResourceGroup -Name $VM -Status
  foreach ($VMStatus in $VMDetail.Statuses) { 
    $Status = $VMStatus.Code      
    if ($Status -eq 'PowerState/running') {
      return $False
    }
  }
  return $True  
}

Function Test-TCPPort ($Server, $Port) {
  $TCPClient = [System.Net.Sockets.TcpClient]::new()
  $Iar = $TCPClient.BeginConnect($Server, $Port, $null, $null)
  $Wait = $Iar.AsyncWaitHandle.WaitOne(1000, $False)
  return $Wait
}

Function Start-Failover {
  foreach ($SubscriptionID in $Script:ListOfSubscriptionIDs) {
    Set-AzContext -SubscriptionId $SubscriptionID
    $TagValue = $env:FWUDRTAG
    $Res = Get-AzResource -TagName nva_ha_udr -TagValue $TagValue

    foreach ($RTable in $Res) {
      $Table = Get-AzRouteTable -ResourceGroupName $RTable.ResourceGroupName -Name $RTable.Name
      
      foreach ($RouteName in $Table.Routes) {
        Write-Output -InputObject "Updating route table..."
        Write-Output -InputObject $RTable.Name

        for ($i = 0; $i -lt $PrimaryInts.count; $i++) {
          if ($RouteName.NextHopIpAddress -eq $SecondaryInts[$i]) {
            Write-Output -InputObject 'Secondary NVA is already ACTIVE'
          }
          elseif ($RouteName.NextHopIpAddress -eq $PrimaryInts[$i]) {
            Set-AzRouteConfig -Name $RouteName.Name  -NextHopType VirtualAppliance -RouteTable $Table -AddressPrefix $RouteName.AddressPrefix -NextHopIpAddress $SecondaryInts[$i]
          }
        }
      }
  
      $UpdateTable = [scriptblock] { param($Table) Set-AzRouteTable -RouteTableObject $Table }
      &$UpdateTable $Table
    }
  }
  Send-AlertMessage -Message "NVA Alert: Failover to Secondary FW2"
}

Function Start-Failback {
  foreach ($SubscriptionID in $Script:ListOfSubscriptionIDs) {
    Set-AzContext -SubscriptionId $SubscriptionID
    $TagValue = $env:FWUDRTAG
    $Res = Get-AzResource -TagName nva_ha_udr -TagValue $TagValue

    foreach ($RTable in $Res) {
      $Table = Get-AzRouteTable -ResourceGroupName $RTable.ResourceGroupName -Name $RTable.Name
      foreach ($RouteName in $Table.Routes) {
        Write-Output -InputObject "Updating route table..."
        Write-Output -InputObject $RTable.Name

        for ($i = 0; $i -lt $PrimaryInts.count; $i++) {
          if ($RouteName.NextHopIpAddress -eq $PrimaryInts[$i]) {
            Write-Output -InputObject 'Primary NVA is already ACTIVE'
          }
          elseif ($RouteName.NextHopIpAddress -eq $SecondaryInts[$i]) {
            Set-AzRouteConfig -Name $RouteName.Name  -NextHopType VirtualAppliance -RouteTable $Table -AddressPrefix $RouteName.AddressPrefix -NextHopIpAddress $PrimaryInts[$i]
          }  
        }
      }  
      $UpdateTable = [scriptblock] { param($Table) Set-AzRouteTable -RouteTableObject $Table }
      &$UpdateTable $Table 
    }
  }
  Send-AlertMessage -Message "NVA Alert: Failback to Primary FW1"
}

Function Get-FWInterfaces {
  $Nics = Get-AzNetworkInterface | Where-Object { $_.VirtualMachine -ne $null }
  $VMS1 = Get-AzVM -Name $VMFW1Name -ResourceGroupName $FW1RGName
  $VMS2 = Get-AzVM -Name $VMFW2Name -ResourceGroupName $FW2RGName

  foreach ($Nic in $Nics) {
    if (($Nic.VirtualMachine.Id -eq $VMS1.Id) -or ($Nic.VirtualMachine.Id -eq $VMS2.Id)) {
      $VM = $VMS | Where-Object { $_.Id -eq $Nic.VirtualMachine.Id }
      $Prv = $Nic.IpConfigurations | Select-Object -ExpandProperty PrivateIpAddress

      if ($VM.Name -eq $VMFW1Name) {
        $Script:PrimaryInts += $Prv
      }
      elseif ($VM.Name -eq $VMFW2Name) {
        $Script:SecondaryInts += $Prv
      }
    }
  }
}

Function Get-Subscriptions {
  Write-Output -InputObject "Enumerating all subscriptions ..."
  $Script:ListOfSubscriptionIDs = (Get-AzSubscription).Id
  Write-Output -InputObject $Script:ListOfSubscriptionIDs
}

#--------------------------------------------------------------------------  
# Main code block for Azure function app                       
#--------------------------------------------------------------------------

$Password = ConvertTo-SecureString $env:SP_PASSWORD -AsPlainText -Force
$Credential = New-Object System.Management.Automation.PSCredential ($env:SP_USERNAME, $Password)
$AzureEnv = Get-AzEnvironment -Name $env:AZURECLOUD
Connect-AzAccount -ServicePrincipal -TenantId $env:TENANTID -Credential $Credential -SubscriptionId $env:SUBSCRIPTIONID -Environment $AzureEnv

$Context = Get-AzContext
Set-AzContext -Context $Context

$Script:PrimaryInts = @()
$Script:SecondaryInts = @()
$Script:ListOfSubscriptionIDs = @()

# Check NVA firewall status using $IntTries tests with $IntSleep between tries

$CtrFW1 = 0
$CtrFW2 = 0
$FW1Down = $True
$FW2Down = $True

$VMS = Get-AzVM

Get-Subscriptions
Get-FWInterfaces

# Test primary and secondary NVA firewall status 
For ($Ctr = 1; $Ctr -le $IntTries; $Ctr++) {
  if ($Monitor -eq 'VMStatus') {
    $FW1Down = Test-VMStatus -VM $VMFW1Name -FWResourceGroup $FW1RGName
    $FW2Down = Test-VMStatus -VM $VMFW2Name -FWResourceGroup $FW2RGName
  }
  if ($Monitor -eq 'TCPPort') {
    $FW1Down = -not (Test-TCPPort -Server $TCPFW1Server -Port $TCPFW1Port)
    $FW2Down = -not (Test-TCPPort -Server $TCPFW2Server -Port $TCPFW2Port)
  }
  Write-Output -InputObject "Pass $Ctr of $IntTries - FW1Down is $FW1Down, FW2Down is $FW2Down"
  if ($FW1Down) { $CtrFW1++ }
  if ($FW2Down) { $CtrFW2++ }
  Write-Output -InputObject "Sleeping $IntSleep seconds"
  Start-Sleep -Seconds $IntSleep
}

# Reset individual test status and determine overall firewalls' status
$FW1Down = $False
$FW2Down = $False

if ($CtrFW1 -eq $IntTries) { $FW1Down = $True }
if ($CtrFW2 -eq $IntTries) { $FW2Down = $True }

# Failover or failback if needed
if (($FW1Down) -and -not ($FW2Down)) {
  if ($FailOver) {
    Write-Output -InputObject 'FW1 Down - Failing over to FW2'
    Start-Failover 
  }
}
elseif (-not ($FW1Down) -and ($FW2Down)) {
  if ($FailBack) {
    Write-Output -InputObject 'FW2 Down - Failing back to FW1'
    Start-Failback
  }
  else {
    Write-Output -InputObject 'FW2 Down - Failing back disabled'
  }
}
elseif (($FW1Down) -and ($FW2Down)) {
  Write-Output -InputObject 'Both FW1 and FW2 Down - Manual recovery action required'
  Send-AlertMessage -Message "NVA Alert: Both FW1 and FW2 Down - Manual recovery action is required"
}
else {
  Write-Output -InputObject 'Both FW1 and FW2 Up - No action is required'
}
