// Demo Activo-Activo en Azure: 2 regiones (VM + PostgreSQL Flexible) + peering + Static Web App.
// Despliegue a nivel suscripción: az deployment sub create -l <regionA> -f infra/main.bicep -p ...
targetScope = 'subscription'

@minLength(2)
@maxLength(6)
@description('Prefijo corto para nombres de recursos (minúsculas)')
param prefix string = 'aa'

@minLength(3)
@maxLength(8)
@description('Sufijo único (minúsculas/números) para nombres globales: DNS labels, PostgreSQL, SWA')
param suffix string

@description('Región A (preferida por el SPA)')
param regionA string = 'centralus'

@description('Región B (failover)')
param regionB string = 'canadacentral'

@description('Región del recurso Static Web App (solo metadatos; el hosting es global). Permitidas: centralus, eastus2, westus2, westeurope, eastasia')
param swaLocation string = 'centralus'

param vmSize string = 'Standard_B2ps_v2'

@description('SKU de la imagen Ubuntu 24.04: server (x64) o server-arm64 (tamaños Arm64 como B2ps_v2 / D2ps_v5)')
param vmImageSku string = 'server-arm64'

@description('Trusted Launch (Secure Boot + vTPM). Desactívalo si el tamaño elegido no lo soporta')
param trustedLaunch bool = false
param pgSku string = 'Standard_B1ms'
param pgVersion string = '16'
param adminUsername string = 'azureuser'

@secure()
param sshPublicKey string

param pgAdminUser string = 'aaadmin'

@secure()
param pgAdminPassword string

@description('Hora de apagado automático diario, formato HHmm')
param shutdownTime string = '2000'

@description('Zona horaria (id de Windows) del apagado automático')
param timeZoneId string = 'Central Standard Time (Mexico)'

@description('CIDR permitido para SSH (vacío = sin SSH, recomendado en MCAPS)')
param allowSshFrom string = ''

param tags object = {
  project: 'activeactive-demo'
  env: 'demo'
  autoshutdown: '20:00'
}

var rgAName = 'rg-${prefix}-a'
var rgBName = 'rg-${prefix}-b'
var rgGName = 'rg-${prefix}-global'

resource rgA 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: rgAName
  location: regionA
  tags: tags
}

resource rgB 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: rgBName
  location: regionB
  tags: tags
}

resource rgG 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: rgGName
  location: swaLocation
  tags: tags
}

module regionAmod 'modules/region.bicep' = {
  scope: rgA
  name: 'region-a-${suffix}'
  params: {
    key: 'a'
    location: regionA
    prefix: prefix
    suffix: suffix
    vnetCidr: '10.10.0.0/16'
    snetVmCidr: '10.10.1.0/24'
    snetPgCidr: '10.10.2.0/24'
    vmPrivateIp: '10.10.1.10'
    peerVnetCidr: '10.20.0.0/16'
    vmSize: vmSize
    vmImageSku: vmImageSku
    trustedLaunch: trustedLaunch
    adminUsername: adminUsername
    sshPublicKey: sshPublicKey
    pgAdminUser: pgAdminUser
    pgAdminPassword: pgAdminPassword
    pgSku: pgSku
    pgVersion: pgVersion
    shutdownTime: shutdownTime
    timeZoneId: timeZoneId
    allowSshFrom: allowSshFrom
    tags: tags
  }
}

module regionBmod 'modules/region.bicep' = {
  scope: rgB
  name: 'region-b-${suffix}'
  params: {
    key: 'b'
    location: regionB
    prefix: prefix
    suffix: suffix
    vnetCidr: '10.20.0.0/16'
    snetVmCidr: '10.20.1.0/24'
    snetPgCidr: '10.20.2.0/24'
    vmPrivateIp: '10.20.1.10'
    peerVnetCidr: '10.10.0.0/16'
    vmSize: vmSize
    vmImageSku: vmImageSku
    trustedLaunch: trustedLaunch
    adminUsername: adminUsername
    sshPublicKey: sshPublicKey
    pgAdminUser: pgAdminUser
    pgAdminPassword: pgAdminPassword
    pgSku: pgSku
    pgVersion: pgVersion
    shutdownTime: shutdownTime
    timeZoneId: timeZoneId
    allowSshFrom: allowSshFrom
    tags: tags
  }
}

module peerAtoB 'modules/peering.bicep' = {
  scope: rgA
  name: 'peer-a-b-${suffix}'
  params: {
    localVnetName: regionAmod.outputs.vnetName
    remoteVnetId: regionBmod.outputs.vnetId
    peerName: 'to-b'
  }
}

module peerBtoA 'modules/peering.bicep' = {
  scope: rgB
  name: 'peer-b-a-${suffix}'
  params: {
    localVnetName: regionBmod.outputs.vnetName
    remoteVnetId: regionAmod.outputs.vnetId
    peerName: 'to-a'
  }
}

module swa 'modules/swa.bicep' = {
  scope: rgG
  name: 'swa-${suffix}'
  params: {
    name: 'swa-${prefix}-${suffix}'
    location: swaLocation
    tags: tags
  }
}

output rgA string = rgAName
output rgB string = rgBName
output rgGlobal string = rgGName
output vmAName string = regionAmod.outputs.vmName
output vmBName string = regionBmod.outputs.vmName
output vmAFqdn string = regionAmod.outputs.vmFqdn
output vmBFqdn string = regionBmod.outputs.vmFqdn
output vmAPrivateIp string = regionAmod.outputs.vmPrivateIp
output vmBPrivateIp string = regionBmod.outputs.vmPrivateIp
output nsgAName string = regionAmod.outputs.nsgName
output nsgBName string = regionBmod.outputs.nsgName
output pgAName string = regionAmod.outputs.pgName
output pgBName string = regionBmod.outputs.pgName
output pgAFqdn string = regionAmod.outputs.pgFqdn
output pgBFqdn string = regionBmod.outputs.pgFqdn
output swaName string = swa.outputs.name
output swaHostname string = swa.outputs.hostname
