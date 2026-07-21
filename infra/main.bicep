// Minimal 2-node Slurm lab: one controller (slurmctld + slurmd) and one compute
// node (slurmd only), no public IPs. Health checks and job submission happen via
// `az vm run-command invoke`, which goes over the Azure control plane through the
// VM agent — no SSH, no open inbound ports, no key management.

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('VM size for both Slurm nodes')
param vmSize string = 'Standard_B2s'

@description('Munge shared secret, base64-encoded, generated fresh per deploy in CI (not committed to the repo)')
@secure()
param mungeKeyBase64 string

@description('Local admin username for the VMs (not used for access — no inbound SSH is opened; required by the VM image)')
param adminUsername string = 'azureuser'

@description('Local admin password for the VMs, generated fresh per deploy in CI (not used for access)')
@secure()
param adminPassword string

@description('Your current public IP in CIDR form (e.g. 203.0.113.5/32), allowed to reach Grafana on port 3000. Nothing else in this template is reachable from the internet.')
param allowedIp string

var subnetAddressPrefix = '10.0.0.0/24'
var controllerIp = '10.0.0.4'
var computeIp = '10.0.0.5'
var monitorIp = '10.0.0.6'

var controllerCloudInit = replace(loadTextContent('cloud-init/controller.yaml'), '__MUNGE_KEY__', mungeKeyBase64)
var computeCloudInit = replace(loadTextContent('cloud-init/compute.yaml'), '__MUNGE_KEY__', mungeKeyBase64)
var monitorCloudInit = loadTextContent('cloud-init/monitor.yaml')

var imageReference = {
  publisher: 'Canonical'
  offer: '0001-com-ubuntu-server-jammy'
  sku: '22_04-lts-gen2'
  version: 'latest'
}

// Mostly empty: Azure's implicit default rules already do what this lab
// needs — deny all inbound from the internet, allow all traffic within the
// VNet (controller <-> compute Slurm/munge traffic, and monitor scraping
// node_exporter over the VNet), allow all outbound (apt/pip package
// installs, the VM agent's control-plane channel for run-command). The one
// explicit rule below is the only inbound-from-internet exception, and it's
// scoped to a single port on a single VM.
resource nsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: 'nsg-slurm-lab'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowGrafanaFromMyIp'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '3000'
          sourceAddressPrefix: allowedIp
          destinationAddressPrefix: monitorIp
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: 'vnet-slurm-lab'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        subnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: 'subnet-slurm'
        properties: {
          addressPrefix: subnetAddressPrefix
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ]
  }
}

resource nicController 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: 'nic-controller'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: controllerIp
          subnet: {
            id: vnet.properties.subnets[0].id
          }
        }
      }
    ]
  }
}

resource nicCompute 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: 'nic-compute'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: computeIp
          subnet: {
            id: vnet.properties.subnets[0].id
          }
        }
      }
    ]
  }
}

// The only public IP in this template — everything else stays reachable
// only via the Azure control plane (`az vm run-command`).
resource pipMonitor 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: 'pip-monitor'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource nicMonitor 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: 'nic-monitor'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: monitorIp
          subnet: {
            id: vnet.properties.subnets[0].id
          }
          publicIPAddress: {
            id: pipMonitor.id
          }
        }
      }
    ]
  }
}

resource vmController 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'vm-controller'
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: 'controller'
      adminUsername: adminUsername
      adminPassword: adminPassword
      customData: base64(controllerCloudInit)
    }
    storageProfile: {
      imageReference: imageReference
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nicController.id
        }
      ]
    }
  }
}

resource vmCompute 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'vm-compute'
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: 'compute'
      adminUsername: adminUsername
      adminPassword: adminPassword
      customData: base64(computeCloudInit)
    }
    storageProfile: {
      imageReference: imageReference
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nicCompute.id
        }
      ]
    }
  }
}

resource vmMonitor 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'vm-monitor'
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: 'monitor'
      adminUsername: adminUsername
      adminPassword: adminPassword
      customData: base64(monitorCloudInit)
    }
    storageProfile: {
      imageReference: imageReference
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nicMonitor.id
        }
      ]
    }
  }
}

output controllerVmName string = vmController.name
output computeVmName string = vmCompute.name
output monitorVmName string = vmMonitor.name
output monitorPublicIp string = pipMonitor.properties.ipAddress
output resourceGroupName string = resourceGroup().name
