// DLP Evidence Download Troubleshooting Infrastructure
// Storage Account + Application Gateway
//
// ROOT CAUSE FIX: App Gateway Backend HTTP Settings must have
// pickHostNameFromBackendAddress = true so the Host header forwarded
// to Azure Blob Storage matches the storage account FQDN.
// Without this, the SAS signature validation fails (AuthenticationFailed).

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Storage account name (3-24 lowercase alphanumeric).')
param storageAccountName string = 'sadlpevidencetest'

@description('Blob container name.')
param containerName string = 'prisma-access'

@description('App Gateway name.')
param appGatewayName string = 'appgw-dlpevidence'

@description('Virtual network name.')
param vnetName string = 'vnet-dlpevidence'

@description('Public IP name for the App Gateway.')
param publicIpName string = 'pip-appgw-dlpevidence'

// Virtual Network with a dedicated /24 subnet for the Application Gateway
resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.0.0.0/16']
    }
    subnets: [
      {
        // Application Gateway requires its own dedicated subnet
        name: 'AppGatewaySubnet'
        properties: {
          addressPrefix: '10.0.1.0/24'
        }
      }
      {
        // Private endpoint for blob storage
        name: 'PrivateEndpointSubnet'
        properties: {
          addressPrefix: '10.0.2.0/24'
        }
      }
    ]
  }
}

var appGatewaySubnetId = vnet.properties.subnets[0].id

// Public IP for the Application Gateway frontend
resource publicIp 'Microsoft.Network/publicIPAddresses@2024-01-01' = {
  name: publicIpName
  location: location
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: appGatewayName
    }
  }
}

// Storage Account — private; access only via private endpoint from the VNet
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    // Public internet access disabled — all traffic flows through the private endpoint
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'None'
    }
  }
}

// Blob container for DLP evidence files
resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
}

resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: containerName
  properties: {
    publicAccess: 'None'
  }
}

// Private Endpoint — exposes the blob service on a NIC inside PrivateEndpointSubnet
resource privateEndpoint 'Microsoft.Network/privateEndpoints@2024-01-01' = {
  name: 'pe-${storageAccountName}-blob'
  location: location
  properties: {
    subnet: {
      id: vnet.properties.subnets[1].id
    }
    privateLinkServiceConnections: [
      {
        name: 'pe-${storageAccountName}-blob-conn'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: ['blob']
        }
      }
    ]
  }
}

// Private DNS Zone — resolves <account>.blob.core.windows.net to the private endpoint IP
resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.blob.${environment().suffixes.storage}'
  location: 'global'
}

// Link the DNS zone to the VNet so the App Gateway DNS resolution uses the private IP
resource dnsVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZone
  name: 'link-${vnetName}'
  location: 'global'
  properties: {
    virtualNetwork: {
      id: vnet.id
    }
    registrationEnabled: false
  }
}

// DNS zone group: auto-registers an A record for the private endpoint NIC IP
resource dnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-01-01' = {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-blob'
        properties: {
          privateDnsZoneId: privateDnsZone.id
        }
      }
    ]
  }
}

// App Gateway
// The blob upload (prisma.txt) and SAS URL generation are done post-deployment
// in deploy.sh using 'az storage blob upload/generate-sas --auth-mode login'.
// Key-based authentication is intentionally avoided (subscription policy).
// CRITICAL: backendHttpSettings uses pickHostNameFromBackendAddress = true
// This ensures the Host header sent to Azure Blob Storage is
//   <storageAccountName>.blob.core.windows.net
// without this the SAS signature validation fails.
resource appGateway 'Microsoft.Network/applicationGateways@2024-01-01' = {
  name: appGatewayName
  location: location
  properties: {
    sku: {
      name: 'Standard_v2'
      tier: 'Standard_v2'
      capacity: 1
    }
    gatewayIPConfigurations: [
      {
        name: 'appGatewayIpConfig'
        properties: {
          subnet: {
            id: appGatewaySubnetId
          }
        }
      }
    ]
    frontendIPConfigurations: [
      {
        name: 'appGatewayFrontendIP'
        properties: {
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
    frontendPorts: [
      {
        name: 'port-80'
        properties: {
          port: 80
        }
      }
    ]
    // Backend pool: points to the storage account blob endpoint
    backendAddressPools: [
      {
        name: 'backendpool-storage'
        properties: {
          backendAddresses: [
            {
              // Strip https:// and trailing / from the blob endpoint to get the FQDN
              fqdn: replace(replace(storageAccount.properties.primaryEndpoints.blob, 'https://', ''), '/', '')
            }
          ]
        }
      }
    ]
    // KEY SETTING: pickHostNameFromBackendAddress = true
    // The Host header forwarded to blob storage MUST be the storage account FQDN
    // so that Azure Storage can validate the SAS signature correctly.
    backendHttpSettingsCollection: [
      {
        name: 'httpsettings-storage'
        properties: {
          port: 443
          protocol: 'Https'
          cookieBasedAffinity: 'Disabled'
          requestTimeout: 30
          // Override Host header with the backend FQDN (storage account hostname)
          // This is the fix for "Signature did not match" SAS errors
          pickHostNameFromBackendAddress: true
          probe: {
            id: resourceId('Microsoft.Network/applicationGateways/probes', appGatewayName, 'probe-storage')
          }
        }
      }
    ]
    probes: [
      {
        name: 'probe-storage'
        properties: {
          protocol: 'Https'
          path: '/${containerName}?restype=container&comp=list'
          interval: 30
          timeout: 30
          unhealthyThreshold: 3
          // Pick host from backend address in the probe too
          pickHostNameFromBackendHttpSettings: true
          match: {
            // 400 is expected without auth — it means the storage endpoint is reachable
            statusCodes: ['200-499']
          }
        }
      }
    ]
    httpListeners: [
      {
        name: 'listener-http'
        properties: {
          frontendIPConfiguration: {
            id: resourceId(
              'Microsoft.Network/applicationGateways/frontendIPConfigurations',
              appGatewayName,
              'appGatewayFrontendIP'
            )
          }
          frontendPort: {
            id: resourceId(
              'Microsoft.Network/applicationGateways/frontendPorts',
              appGatewayName,
              'port-80'
            )
          }
          protocol: 'Http'
        }
      }
    ]
    requestRoutingRules: [
      {
        name: 'rule-storage'
        properties: {
          ruleType: 'Basic'
          priority: 100
          httpListener: {
            id: resourceId(
              'Microsoft.Network/applicationGateways/httpListeners',
              appGatewayName,
              'listener-http'
            )
          }
          backendAddressPool: {
            id: resourceId(
              'Microsoft.Network/applicationGateways/backendAddressPools',
              appGatewayName,
              'backendpool-storage'
            )
          }
          backendHttpSettings: {
            id: resourceId(
              'Microsoft.Network/applicationGateways/backendHttpSettingsCollection',
              appGatewayName,
              'httpsettings-storage'
            )
          }
        }
      }
    ]
  }
}

// Outputs
output storageAccountName string = storageAccount.name
output storageAccountBlobEndpoint string = storageAccount.properties.primaryEndpoints.blob
output appGatewayPublicIp string = publicIp.properties.ipAddress
output appGatewayFqdn string = publicIp.properties.dnsSettings.fqdn
output downloadUrlPattern string = 'http://${publicIp.properties.ipAddress}/${containerName}/prisma.txt?<SAS_QUERY_STRING>'
