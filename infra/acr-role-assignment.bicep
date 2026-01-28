// ACR Role Assignment Module
// Grants a role to a principal on the shared ACR

@description('Name of the ACR')
param acrName string

@description('Principal ID to grant the role to')
param principalId string

@description('Role definition ID to assign')
param roleDefinitionId string

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
    name: acrName
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
    name: guid(acr.id, roleDefinitionId, principalId)
    scope: acr
    properties: {
        principalId: principalId
        roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
        principalType: 'ServicePrincipal'
    }
}
