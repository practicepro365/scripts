// PracticePro 365 - Synapse Link Infrastructure
// Deploy to Azure portal template
// Naming convention: resources use companyId + environment suffix
targetScope = 'resourceGroup'

// ===========================
// Parameters
// ===========================

@minLength(3)
@maxLength(5)
@description('Short company identifier (3-5 lowercase letters). Example: Bank of America → bofa')
param companyId string

@allowed(['prod', 'dev', 'uat', 'test'])
@description('Deployment environment. Defaults to prod. Change only when instructed by PracticePro 365 team.')
param deployEnvironment string = 'prod'

@description('User email (UPN). Example: admin@contoso.com')
param userUpn string

@description('User Object ID (GUID). Find it in Entra ID → Users → select user → Object ID field on the Overview page.')
param userObjectId string

@secure()
@description('Password for the Synapse SQL administrator account.')
param sqlAdminPassword string

// ===========================
// Variables - Naming Convention
// ===========================

var storageAccountName = toLower('st${companyId}pp365synapse${deployEnvironment}')
var synapseWorkspaceName = toLower('synw-${companyId}pp365-${deployEnvironment}')
var fileSystemName = 'dataverse-practicepro-slink'
var sqlAdminLogin = 'sqladminuser'
var managedRgName = 'synw-managed-${synapseWorkspaceName}'

// Well-known role definition IDs
var roleOwner = '8e3af657-a8ff-443c-a75c-2fe8c4bcb635'
var roleUserAccessAdmin = '18d7d88d-d35e-4fb5-a5c3-7773c20a72d9'
var roleStorageBlobDataContributor = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var roleStorageBlobDataOwner = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'

// Synapse data-plane RBAC role ID for "Synapse Administrator"
// This is a fixed well-known GUID across all Synapse workspaces
var synapseAdministratorRoleId = '6e4bf58a-b8e1-4cc3-bbf9-d73143322b78'

// ===========================
// Resource Group RBAC
// Owner + User Access Administrator WITHOUT ABAC conditions
// By deploying these through ARM (no condition/conditionVersion properties),
// the roles are assigned cleanly without ABAC restrictions.
// This prevents the issue where manually-assigned Owner roles with ABAC
// block resource creation and role assignment during Synapse Link setup.
// ===========================

resource rgOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, userObjectId, roleOwner)
  properties: {
    principalId: userObjectId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleOwner)
    principalType: 'User'
    description: 'PracticePro 365 - Owner (no ABAC conditions)'
  }
}

resource rgUserAccessAdmin 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, userObjectId, roleUserAccessAdmin)
  properties: {
    principalId: userObjectId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleUserAccessAdmin)
    principalType: 'User'
    description: 'PracticePro 365 - User Access Administrator (no ABAC conditions)'
  }
}

// ===========================
// Storage Account (ADLS Gen2)
// ===========================

resource stg 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: resourceGroup().location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    isHnsEnabled: true
    allowSharedKeyAccess: true
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: stg
  name: 'default'
}

resource fs 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: fileSystemName
  properties: {
    publicAccess: 'None'
  }
}

// ===========================
// Storage RBAC
// ===========================

resource stgBlobDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(stg.id, userObjectId, roleStorageBlobDataContributor)
  scope: stg
  properties: {
    principalId: userObjectId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleStorageBlobDataContributor)
    principalType: 'User'
  }
}

resource stgBlobDataOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(stg.id, userObjectId, roleStorageBlobDataOwner)
  scope: stg
  properties: {
    principalId: userObjectId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleStorageBlobDataOwner)
    principalType: 'User'
  }
}

// ===========================
// Synapse Workspace
// ===========================

resource synw 'Microsoft.Synapse/workspaces@2021-06-01' = {
  name: synapseWorkspaceName
  location: resourceGroup().location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    azureADOnlyAuthentication: false
    defaultDataLakeStorage: {
      accountUrl: 'https://${storageAccountName}.dfs.${az.environment().suffixes.storage}'
      filesystem: fileSystemName
    }
    sqlAdministratorLogin: sqlAdminLogin
    sqlAdministratorLoginPassword: sqlAdminPassword
    cspWorkspaceAdminProperties: {
      initialWorkspaceAdminObjectId: userObjectId
    }
    managedResourceGroupName: managedRgName
  }
  dependsOn: [
    stg
    fs
  ]
}

// ===========================
// Synapse Entra Admin
// ===========================

resource synwAadAdmin 'Microsoft.Synapse/workspaces/administrators@2021-06-01' = {
  parent: synw
  name: 'activeDirectory'
  properties: {
    administratorType: 'ActiveDirectory'
    login: userUpn
    sid: userObjectId
    tenantId: tenant().tenantId
  }
}

// Allow both Entra ID and SQL auth
resource synwEntraOnly 'Microsoft.Synapse/workspaces/azureADOnlyAuthentications@2021-06-01' = {
  parent: synw
  name: 'default'
  properties: {
    azureADOnlyAuthentication: false
  }
}

// ===========================
// Firewall Rules
// ===========================
// Note: synwFirewallAllowAllPublic must be deployed before the deployment script below,
// because the script container runs from Azure infrastructure and needs public access
// to reach the Synapse data-plane endpoint.

// Required for Dataverse Synapse Link
resource synwFirewallAllowAzure 'Microsoft.Synapse/workspaces/firewallRules@2021-06-01' = {
  parent: synw
  name: 'AllowAllWindowsAzureIps'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

// Open public access by default for initial setup
resource synwFirewallAllowAllPublic 'Microsoft.Synapse/workspaces/firewallRules@2021-06-01' = {
  parent: synw
  name: 'AllowAllPublicIps'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '255.255.255.255'
  }
}

// ===========================
// Synapse RBAC - Deployment Script
// Assigns the Synapse Administrator data-plane role to the user.
// This cannot be done via ARM/Bicep directly because it requires calling
// the Synapse data-plane API (https://{workspace}.dev.azuresynapse.net/rbac/...)
// rather than the ARM control plane.
// ===========================

// Managed identity used by the deployment script to authenticate to Azure
resource scriptIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-synapse-deploy-${synapseWorkspaceName}'
  location: resourceGroup().location
}

// Grant the script identity Owner on this RG so it can call the Synapse data-plane RBAC API
resource scriptIdentityOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, scriptIdentity.id, roleOwner)
  properties: {
    principalId: scriptIdentity.properties.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleOwner)
    principalType: 'ServicePrincipal'
    description: 'PracticePro 365 - Deployment script identity (auto-removed after retentionInterval)'
  }
}

resource assignSynapseAdminRole 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'assignSynapseAdminRole'
  location: resourceGroup().location
  kind: 'AzureCLI'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${scriptIdentity.id}': {}
    }
  }
  properties: {
    azCliVersion: '2.59.0'
    retentionInterval: 'PT1H'
    timeout: 'PT10M'
    scriptContent: '''
      # Assign Synapse Administrator data-plane role (idempotent)
      EXISTING=$(az synapse role assignment list \
        --workspace-name "$SYNAPSE_WORKSPACE" \
        --role "$SYNAPSE_ROLE_ID" \
        --assignee-object-id "$USER_OBJECT_ID" \
        --query "[0].id" -o tsv 2>/dev/null)

      if [ -n "$EXISTING" ]; then
        echo "Synapse Administrator role already assigned. Skipping."
      else
        az synapse role assignment create \
          --workspace-name "$SYNAPSE_WORKSPACE" \
          --role "$SYNAPSE_ROLE_ID" \
          --assignee-object-id "$USER_OBJECT_ID" \
          --assignee-principal-type User
        echo "Synapse Administrator role assigned successfully."
      fi
    '''
    environmentVariables: [
      { name: 'SYNAPSE_WORKSPACE', value: synapseWorkspaceName }
      { name: 'USER_OBJECT_ID', value: userObjectId }
      { name: 'SYNAPSE_ROLE_ID', value: synapseAdministratorRoleId }
    ]
  }
  dependsOn: [
    synw
    synwFirewallAllowAllPublic
    scriptIdentityOwner
  ]
}

// ===========================
// Outputs
// ===========================

output storageAccountName string = stg.name
output storageAccountId string = stg.id
output synapseWorkspaceName string = synw.name
output synapseWorkspaceId string = synw.id
output synapseDevEndpoint string = synw.properties.connectivityEndpoints.dev
output fileSystemName string = fs.name
output resourceGroupName string = resourceGroup().name
output namingConvention object = {
  storageAccount: storageAccountName
  synapseWorkspace: synapseWorkspaceName
  fileSystem: fileSystemName
  managedResourceGroup: managedRgName
}
