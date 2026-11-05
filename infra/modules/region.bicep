// Una región completa: VNet (snet-vm + snet-pg delegada), NSG sin puertos de gestión, IP pública estática
// con DNS label, VM Ubuntu 24.04 (Docker vía cloud-init), auto-shutdown, PostgreSQL Flexible Server privado
// con wal_level=logical (CDC) y Private DNS zone.
param key string
param location string
param prefix string
param suffix string
param vnetCidr string
param snetVmCidr string
param snetPgCidr string
param vmPrivateIp string
param peerVnetCidr string
param vmSize string
param vmImageSku string
param trustedLaunch bool
param adminUsername string
@secure()
param sshPublicKey string
param pgAdminUser string
@secure()
param pgAdminPassword string
param pgSku string
param pgVersion string
param shutdownTime string
param timeZoneId string
param allowSshFrom string
param tags object

var vnetName = 'vnet-${prefix}-${key}'
var nsgName = 'nsg-${prefix}-${key}'
var vmName = 'vm-${prefix}-${key}'
var pgName = 'pg-${prefix}-${suffix}-${key}'
var dnsLabel = '${prefix}-${suffix}-${key}'
var dnsZoneName = '${prefix}-${suffix}-${key}.private.postgres.database.azure.com'
var cloudInit = loadTextContent('../../vm/cloud-init.yaml')

var baseRules = [
  {
    name: 'AllowHTTPS-Internet'
    properties: {
      priority: 100
      direction: 'Inbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: 'Internet'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '443'
      description: 'API y SPA (Caddy TLS)'
    }
  }
  {
    name: 'AllowHTTP-ACME'
    properties: {
      priority: 110
      direction: 'Inbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: 'Internet'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '80'
      description: 'Reto ACME HTTP-01 y redirección a HTTPS'
    }
  }
  {
    name: 'AllowKafka-PeerVnet'
    properties: {
      priority: 120
      direction: 'Inbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: peerVnetCidr
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '9092'
      description: 'Replicator de la región par consume Kafka por peering'
    }
  }
]
var sshRule = [
  {
    name: 'AllowSSH-Operator'
    properties: {
      priority: 130
      direction: 'Inbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: allowSshFrom
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '22'
      description: 'SSH solo desde la IP del operador (opcional)'
    }
  }
]

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-01-01' = {
  name: nsgName
  location: location
  tags: tags
  properties: {
    securityRules: concat(baseRules, empty(allowSshFrom) ? [] : sshRule)
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [vnetCidr]
    }
    subnets: [
      {
        name: 'snet-vm'
        properties: {
          addressPrefix: snetVmCidr
          defaultOutboundAccess: false
          // El NSG también va en la subred: la gobernanza MCAPS asocia un NSG propio (solo reglas por defecto,
          // que deniegan 443/80 desde Internet) a toda subred que no tenga uno.
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
      {
        name: 'snet-pg'
        properties: {
          addressPrefix: snetPgCidr
          delegations: [
            {
              name: 'pg-flexible'
              properties: {
                serviceName: 'Microsoft.DBforPostgreSQL/flexibleServers'
              }
            }
          ]
        }
      }
    ]
  }
}

resource dnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: dnsZoneName
  location: 'global'
  tags: tags
}

resource dnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: dnsZone
  name: 'link-${vnetName}'
  location: 'global'
  properties: {
    virtualNetwork: {
      id: vnet.id
    }
    registrationEnabled: false
  }
}

resource pg 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = {
  name: pgName
  location: location
  tags: tags
  sku: {
    name: pgSku
    tier: 'Burstable'
  }
  properties: {
    version: pgVersion
    administratorLogin: pgAdminUser
    administratorLoginPassword: pgAdminPassword
    createMode: 'Default'
    storage: {
      storageSizeGB: 32
      autoGrow: 'Disabled'
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    highAvailability: {
      mode: 'Disabled'
    }
    network: {
      delegatedSubnetResourceId: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'snet-pg')
      privateDnsZoneArmResourceId: dnsZone.id
    }
    authConfig: {
      passwordAuth: 'Enabled'
      activeDirectoryAuth: 'Disabled'
    }
  }
  dependsOn: [
    vnet
    dnsLink
  ]
}

resource pgDb 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2024-08-01' = {
  parent: pg
  name: 'appdb'
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
}

// wal_level=logical habilita la decodificación lógica (Debezium). Requiere reinicio (lo hace deploy.sh).
resource cfgWal 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2024-08-01' = {
  parent: pg
  name: 'wal_level'
  properties: {
    value: 'logical'
    source: 'user-override'
  }
  dependsOn: [pgDb]
}

// Nota: max_slot_wal_keep_size es de solo lectura en Flexible Server (lo gestiona Azure); el heartbeat de Debezium
// y el apagado nocturno de Postgres (scripts/stop.sh --db) son la protección contra WAL retenido por un slot inactivo.

resource pip 'Microsoft.Network/publicIPAddresses@2024-01-01' = {
  name: 'pip-${vmName}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    dnsSettings: {
      domainNameLabel: dnsLabel
    }
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2024-01-01' = {
  name: 'nic-${vmName}'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'snet-vm')
          }
          privateIPAllocationMethod: 'Static'
          privateIPAddress: vmPrivateIp
          publicIPAddress: {
            id: pip.id
          }
        }
      }
    ]
    networkSecurityGroup: {
      id: nsg.id
    }
  }
  dependsOn: [vnet]
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: vmImageSku
        version: 'latest'
      }
      osDisk: {
        name: 'osdisk-${vmName}'
        createOption: 'FromImage'
        diskSizeGB: 64
        deleteOption: 'Delete'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      customData: base64(cloudInit)
      linuxConfiguration: {
        disablePasswordAuthentication: true
        provisionVMAgent: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
        patchSettings: {
          patchMode: 'ImageDefault'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }
    securityProfile: trustedLaunch ? {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    } : null
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

// Apagado automático diario (mismo mecanismo que el portal; sin costo).
resource shutdown 'Microsoft.DevTestLab/schedules@2018-09-15' = {
  name: 'shutdown-computevm-${vmName}'
  location: location
  tags: tags
  properties: {
    status: 'Enabled'
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: {
      time: shutdownTime
    }
    timeZoneId: timeZoneId
    notificationSettings: {
      status: 'Disabled'
      timeInMinutes: 30
    }
    targetResourceId: vm.id
  }
}

output vnetName string = vnet.name
output vnetId string = vnet.id
output nsgName string = nsg.name
output vmName string = vm.name
output vmFqdn string = pip.properties.dnsSettings.fqdn
output vmPrivateIp string = vmPrivateIp
output pgName string = pg.name
output pgFqdn string = pg.properties.fullyQualifiedDomainName
