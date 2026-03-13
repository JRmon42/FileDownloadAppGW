using './main.bicep'

param location = 'francecentral'
param storageAccountName = 'sadlpevidencetest'
param containerName = 'prisma-access'
param appGatewayName = 'appgw-dlpevidence'
param vnetName = 'vnet-dlpevidence'
param publicIpName = 'pip-appgw-dlpevidence'
