// Azure Static Web Apps (plan Free): hosting global del SPA. El contenido se publica con la SWA CLI (scripts/deploy-web.sh).
param name string
param location string
param tags object

resource swa 'Microsoft.Web/staticSites@2023-12-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: 'Free'
    tier: 'Free'
  }
  properties: {
    stagingEnvironmentPolicy: 'Enabled'
    allowConfigFileUpdates: true
  }
}

output name string = swa.name
output hostname string = swa.properties.defaultHostname
