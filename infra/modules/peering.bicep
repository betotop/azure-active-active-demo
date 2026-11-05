// Peering global de VNets (una dirección; main.bicep lo invoca dos veces).
param localVnetName string
param remoteVnetId string
param peerName string

resource peering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-01-01' = {
  name: '${localVnetName}/${peerName}'
  properties: {
    remoteVirtualNetwork: {
      id: remoteVnetId
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}
