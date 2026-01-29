// Happy Server Infrastructure for Azure
// Deploys: Container Apps Environment, Container App, PostgreSQL, Redis, MinIO (S3)
// Uses shared ACR from mx-ae-rg-shared-services

@description('Environment name (e.g., prod, staging)')
param environmentName string = 'prod'

@description('Azure region for resources')
param location string = resourceGroup().location

@description('Container image tag to deploy')
param imageTag string = 'latest'

@description('PostgreSQL administrator password')
@secure()
param postgresPassword string

@description('Server seed for secure token generation')
@secure()
param serverSeed string

@description('MinIO root password')
@secure()
param minioPassword string

@description('Master secret for encryption')
@secure()
param handyMasterSecret string

@description('Shared ACR name')
param acrName string = 'mxaesharedservicesacr'

// Resource naming
var prefix = 'happy-${environmentName}'
var containerAppEnvName = '${prefix}-env'
var containerAppName = '${prefix}-server'
var minioAppName = '${prefix}-minio'
var postgresServerName = '${prefix}-pg'
var redisName = replace('${prefix}-redis', '-', '')
var logAnalyticsName = '${prefix}-logs'
var managedIdentityName = '${prefix}-identity'
var storageAccountName = replace('${prefix}storage', '-', '')

// Shared services
var sharedServicesSubscriptionId = '50145306-fa25-4495-8c12-1dded290efe1'
var sharedServicesResourceGroup = 'mx-ae-rg-shared-services'
var acrLoginServer = '${acrName}.azurecr.io'

// AcrPull role ID
var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'

// MinIO credentials
var minioUser = 'minioadmin'

// Log Analytics Workspace (required for Container Apps)
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
    name: logAnalyticsName
    location: location
    properties: {
        sku: {
            name: 'PerGB2018'
        }
        retentionInDays: 30
    }
}

// User-assigned managed identity for the container app
resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
    name: managedIdentityName
    location: location
}

// Reference the shared ACR
resource sharedAcr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
    name: acrName
    scope: resourceGroup(sharedServicesSubscriptionId, sharedServicesResourceGroup)
}

// Grant ACR pull permission to the managed identity
module acrPullRoleAssignment 'acr-role-assignment.bicep' = {
    name: '${prefix}-acr-pull'
    scope: resourceGroup(sharedServicesSubscriptionId, sharedServicesResourceGroup)
    params: {
        acrName: acrName
        principalId: managedIdentity.properties.principalId
        roleDefinitionId: acrPullRoleId
    }
}

// Azure Cache for Redis
resource redis 'Microsoft.Cache/redis@2023-08-01' = {
    name: redisName
    location: location
    properties: {
        sku: {
            name: 'Basic'
            family: 'C'
            capacity: 0
        }
        enableNonSslPort: false
        minimumTlsVersion: '1.2'
    }
}

// PostgreSQL Flexible Server
resource postgresServer 'Microsoft.DBforPostgreSQL/flexibleServers@2023-06-01-preview' = {
    name: postgresServerName
    location: location
    sku: {
        name: 'Standard_B1ms'
        tier: 'Burstable'
    }
    properties: {
        version: '15'
        administratorLogin: 'happyadmin'
        administratorLoginPassword: postgresPassword
        storage: {
            storageSizeGB: 32
        }
        backup: {
            backupRetentionDays: 7
            geoRedundantBackup: 'Disabled'
        }
        highAvailability: {
            mode: 'Disabled'
        }
    }
}

// PostgreSQL Database
resource postgresDatabase 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2023-06-01-preview' = {
    parent: postgresServer
    name: 'happy'
    properties: {
        charset: 'UTF8'
        collation: 'en_US.utf8'
    }
}

// Allow Azure services to access PostgreSQL
resource postgresFirewall 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2023-06-01-preview' = {
    parent: postgresServer
    name: 'AllowAzureServices'
    properties: {
        startIpAddress: '0.0.0.0'
        endIpAddress: '0.0.0.0'
    }
}

// Azure Storage Account for MinIO persistent storage
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
    name: storageAccountName
    location: location
    sku: {
        name: 'Standard_LRS'
    }
    kind: 'StorageV2'
    properties: {
        accessTier: 'Hot'
    }
}

// File share for MinIO data
resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-01-01' = {
    parent: storageAccount
    name: 'default'
}

resource minioFileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-01-01' = {
    parent: fileService
    name: 'minio-data'
    properties: {
        shareQuota: 10
    }
}

// Container Apps Environment
resource containerAppEnv 'Microsoft.App/managedEnvironments@2023-05-01' = {
    name: containerAppEnvName
    location: location
    properties: {
        appLogsConfiguration: {
            destination: 'log-analytics'
            logAnalyticsConfiguration: {
                customerId: logAnalytics.properties.customerId
                sharedKey: logAnalytics.listKeys().primarySharedKey
            }
        }
    }
}

// Storage mount for MinIO
resource minioStorage 'Microsoft.App/managedEnvironments/storages@2023-05-01' = {
    parent: containerAppEnv
    name: 'minio-storage'
    properties: {
        azureFile: {
            accountName: storageAccount.name
            accountKey: storageAccount.listKeys().keys[0].value
            shareName: minioFileShare.name
            accessMode: 'ReadWrite'
        }
    }
}

// Container App - MinIO (S3-compatible storage)
resource minioApp 'Microsoft.App/containerApps@2023-05-01' = {
    name: minioAppName
    location: location
    properties: {
        managedEnvironmentId: containerAppEnv.id
        configuration: {
            ingress: {
                external: false
                targetPort: 9000
                transport: 'http'
                allowInsecure: true
            }
            secrets: [
                {
                    name: 'minio-root-password'
                    value: minioPassword
                }
            ]
        }
        template: {
            containers: [
                {
                    name: 'minio'
                    image: 'minio/minio:latest'
                    resources: {
                        cpu: json('0.25')
                        memory: '0.5Gi'
                    }
                    env: [
                        {
                            name: 'MINIO_ROOT_USER'
                            value: minioUser
                        }
                        {
                            name: 'MINIO_ROOT_PASSWORD'
                            secretRef: 'minio-root-password'
                        }
                    ]
                    command: [
                        'minio'
                        'server'
                        '/data'
                        '--console-address'
                        ':9001'
                    ]
                    volumeMounts: [
                        {
                            volumeName: 'minio-data'
                            mountPath: '/data'
                        }
                    ]
                    probes: [
                        {
                            type: 'Liveness'
                            httpGet: {
                                path: '/minio/health/live'
                                port: 9000
                            }
                            initialDelaySeconds: 10
                            periodSeconds: 10
                        }
                        {
                            type: 'Readiness'
                            httpGet: {
                                path: '/minio/health/ready'
                                port: 9000
                            }
                            initialDelaySeconds: 5
                            periodSeconds: 5
                        }
                    ]
                }
            ]
            volumes: [
                {
                    name: 'minio-data'
                    storageName: minioStorage.name
                    storageType: 'AzureFile'
                }
            ]
            scale: {
                minReplicas: 1
                maxReplicas: 1
            }
        }
    }
}

// Container App - Happy Server
resource containerApp 'Microsoft.App/containerApps@2023-05-01' = {
    name: containerAppName
    location: location
    identity: {
        type: 'UserAssigned'
        userAssignedIdentities: {
            '${managedIdentity.id}': {}
        }
    }
    properties: {
        managedEnvironmentId: containerAppEnv.id
        configuration: {
            ingress: {
                external: true
                targetPort: 3000
                transport: 'http'
                allowInsecure: false
            }
            registries: [
                {
                    server: acrLoginServer
                    identity: managedIdentity.id
                }
            ]
            secrets: [
                {
                    name: 'database-url'
                    value: 'postgresql://happyadmin:${uriComponent(postgresPassword)}@${postgresServer.properties.fullyQualifiedDomainName}:5432/happy?sslmode=require'
                }
                {
                    name: 'redis-url'
                    value: 'rediss://:${uriComponent(redis.listKeys().primaryKey)}@${redis.properties.hostName}:6380'
                }
                {
                    name: 'server-seed'
                    value: serverSeed
                }
                {
                    name: 'minio-secret-key'
                    value: minioPassword
                }
                {
                    name: 'handy-master-secret'
                    value: handyMasterSecret
                }
            ]
        }
        template: {
            containers: [
                {
                    name: 'happy-server'
                    image: '${acrLoginServer}/happy-server:${imageTag}'
                    resources: {
                        cpu: json('0.5')
                        memory: '1Gi'
                    }
                    env: [
                        {
                            name: 'NODE_ENV'
                            value: 'production'
                        }
                        {
                            name: 'PORT'
                            value: '3000'
                        }
                        {
                            name: 'DATABASE_URL'
                            secretRef: 'database-url'
                        }
                        {
                            name: 'REDIS_URL'
                            secretRef: 'redis-url'
                        }
                        {
                            name: 'SEED'
                            secretRef: 'server-seed'
                        }
                        {
                            name: 'S3_HOST'
                            value: minioApp.properties.configuration.ingress.fqdn
                        }
                        {
                            name: 'S3_PORT'
                            value: '80'
                        }
                        {
                            name: 'S3_USE_SSL'
                            value: 'false'
                        }
                        {
                            name: 'S3_ACCESS_KEY'
                            value: minioUser
                        }
                        {
                            name: 'S3_SECRET_KEY'
                            secretRef: 'minio-secret-key'
                        }
                        {
                            name: 'S3_BUCKET'
                            value: 'happy'
                        }
                        {
                            name: 'S3_PUBLIC_URL'
                            value: 'http://${minioApp.properties.configuration.ingress.fqdn}/happy'
                        }
                        {
                            name: 'HANDY_MASTER_SECRET'
                            secretRef: 'handy-master-secret'
                        }
                    ]
                    probes: [
                        {
                            type: 'Liveness'
                            httpGet: {
                                path: '/health'
                                port: 3000
                            }
                            initialDelaySeconds: 10
                            periodSeconds: 5
                            timeoutSeconds: 3
                            failureThreshold: 3
                        }
                        {
                            type: 'Readiness'
                            httpGet: {
                                path: '/health'
                                port: 3000
                            }
                            initialDelaySeconds: 5
                            periodSeconds: 5
                            timeoutSeconds: 3
                            failureThreshold: 3
                        }
                    ]
                }
            ]
            scale: {
                minReplicas: 1
                maxReplicas: 3
                rules: [
                    {
                        name: 'http-scaling'
                        http: {
                            metadata: {
                                concurrentRequests: '100'
                            }
                        }
                    }
                ]
            }
        }
    }
    dependsOn: [
        acrPullRoleAssignment
        minioApp
    ]
}

// Outputs
output containerAppUrl string = 'https://${containerApp.properties.configuration.ingress.fqdn}'
output minioInternalUrl string = 'http://${minioApp.properties.configuration.ingress.fqdn}'
output postgresServerFqdn string = postgresServer.properties.fullyQualifiedDomainName
output redisHostName string = redis.properties.hostName
output managedIdentityClientId string = managedIdentity.properties.clientId
