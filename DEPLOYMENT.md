# Happy Server - Azure Deployment Guide

This guide covers deploying the Happy Server to Azure Container Apps for MakerX.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                 mx-ae-rg-shared-services                        │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  mxaesharedservicesacr (Shared ACR)                       │  │
│  │  - happy-server:latest                                    │  │
│  │  - happy-server:<sha>                                     │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼ (AcrPull via Managed Identity)
┌─────────────────────────────────────────────────────────────────┐
│                 mx-ae-prod-happyserver-rg                       │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  Container Apps Environment (happy-prod-env)            │   │
│  │  ┌─────────────────────────────────────────────────┐   │   │
│  │  │  happy-prod-server (Container App)              │   │   │
│  │  │  - Port 3000                                    │   │   │
│  │  │  - Auto-scaling 1-3 replicas                    │   │   │
│  │  │  - Managed Identity for ACR access              │   │   │
│  │  └───────────────────────────────────────────────────┘   │   │
│  └─────────────────────────────────────────────────────────┘   │
│                              │                                  │
│            ┌─────────────────┴─────────────────┐               │
│            ▼                                   ▼               │
│  ┌─────────────────┐                ┌─────────────────┐       │
│  │  PostgreSQL     │                │  Redis Cache    │       │
│  │  happy-prod-pg  │                │  happyprodredis │       │
│  │  (Burstable)    │                │  (Basic C0)     │       │
│  └─────────────────┘                └─────────────────┘       │
└─────────────────────────────────────────────────────────────────┘
```

## Prerequisites

1. **MakerX deployment setup** - happy-server must be added to `makerx-azure-deployment-setup`
2. **GitHub environments** - `prod` environment configured in the repo

## Setup Steps

### 1. Add to MakerX Deployment Setup (Already Done)

The happy-server entry has been added to `prod.bicepparam` in `makerx-azure-deployment-setup`:

```bicep
{
    name: 'happy-server'
    resourceGroup: 'mx-ae-prod-happyserver-rg'
    uniqueId: 'github_com_MakerXStudio_happy-server_Prod'
}
```

**Action:** Create a PR in `makerx-azure-deployment-setup` and merge it.

### 2. Configure GitHub Environment

After the deployment-setup PR is merged, check the Actions output for:
- `AZURE_CLIENT_ID`
- `AZURE_TENANT_ID`
- `AZURE_SUBSCRIPTION_ID`

Go to: https://github.com/MakerXStudio/happy-server/settings/environments

1. Create environment: `prod`
2. Add these as **environment variables** (not secrets):
   - `AZURE_CLIENT_ID`
   - `AZURE_TENANT_ID`
   - `AZURE_SUBSCRIPTION_ID`

### 3. Add Repository Secrets

Go to: https://github.com/MakerXStudio/happy-server/settings/secrets/actions

Add these **repository secrets**:

| Secret | Description | How to Generate |
|--------|-------------|-----------------|
| `POSTGRES_PASSWORD` | PostgreSQL admin password | `openssl rand -base64 32` |
| `SERVER_SEED` | Cryptographic seed | `openssl rand -hex 32` |

### 4. Deploy

Push to `main` to trigger deployment:

```bash
git add .
git commit -m "Add Azure infrastructure"
git push origin main
```

## How It Works

### Authentication (OIDC)
- No stored secrets for Azure login
- GitHub Actions authenticates via federated identity
- The deployment-setup repo configures the trust relationship

### Container Registry
- Uses shared ACR: `mxaesharedservicesacr.azurecr.io`
- Build job pushes images with AcrPush role
- Container App pulls images via managed identity with AcrPull role

### Infrastructure
- Bicep templates deploy PostgreSQL, Redis, and Container Apps
- Managed identity handles ACR authentication
- All resources in `mx-ae-prod-happyserver-rg`

## Monitoring

### View Logs
```bash
az containerapp logs show \
    --name happy-prod-server \
    --resource-group mx-ae-prod-happyserver-rg \
    --follow
```

### Health Check
```bash
curl https://<app-url>/health
```

### Check App Status
```bash
az containerapp show \
    --name happy-prod-server \
    --resource-group mx-ae-prod-happyserver-rg \
    --query "properties.runningStatus"
```

## Client Configuration

Once deployed, configure clients:

**Mobile App:**
Settings → Relay Server URL → `https://<app-fqdn>`

**CLI:**
```bash
export HAPPY_SERVER_URL="https://<app-fqdn>"
```

## Troubleshooting

### Build fails with ACR login error
- Ensure deployment-setup PR is merged
- Check that `prod` environment has the correct vars

### Container fails to pull image
- Verify managed identity has AcrPull on shared ACR
- Check the acrPullRoleAssignment module deployed successfully

### Database connection issues
- Verify firewall rule allows Azure services
- Check DATABASE_URL secret is correct

### Redis connection issues
- Ensure using `rediss://` (with SSL) on port 6380
- Check Redis firewall settings
