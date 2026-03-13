# FileDownloadAppGW

Azure IaaS infrastructure to troubleshoot and validate **SAS-authenticated file downloads through an Application Gateway**, reproducing the Palo Alto DLP evidence download use case.

## Context

When a DLP incident is generated, the Palo Alto DLP solution stores evidence files in an Azure Storage Account and redirects the DLP admin to a signed URL to download the file. The redirect URL points to an **Application Gateway** (not directly to blob storage).

The symptom is an `AuthenticationFailed / Signature did not match` error:

```xml
<Error>
  <Code>AuthenticationFailed</Code>
  <AuthenticationErrorDetail>Signature did not match. String to sign used was ...</AuthenticationErrorDetail>
</Error>
```

### Root Cause

The SAS token signature is bound to the storage account hostname (`<account>.blob.core.windows.net`). When the Application Gateway forwards the request to blob storage **without overriding the `Host` header**, Azure Storage sees the wrong host and rejects the signature.

### Fix

Set `pickHostNameFromBackendAddress: true` on the App Gateway **Backend HTTP Settings**. This forces the App Gateway to forward `Host: <storageaccount>.blob.core.windows.net` on every proxied request, so the SAS signature matches.

---

## Architecture

```
Edge browser  ──HTTP──▶  App Gateway (port 80, public FQDN)
                                │
                                │  Host: sadlpevidencetest.blob.core.windows.net
                                │  pickHostNameFromBackendAddress = true
                                ▼
                         Azure Blob Storage (HTTPS 443)
                         container: prisma-access / prisma.txt
```

### Resources deployed

| Resource | Name | Notes |
|---|---|---|
| Virtual Network | `vnet-dlpevidence` | `10.0.0.0/16` |
| Subnet | `AppGatewaySubnet` | `10.0.1.0/24` — dedicated as required |
| Public IP | `pip-appgw-dlpevidence` | Standard SKU, static, with DNS label |
| Storage Account | `sadlpevidencetest` | Standard LRS, TLS 1.2, no public blob access, **key-based auth disabled** |
| Blob Container | `prisma-access` | Matches the DLP incident URL path |
| Application Gateway | `appgw-dlpevidence` | Standard_v2, HTTP listener on port 80 |

---

## Files

| File | Description |
|---|---|
| `main.bicep` | Full IaaS Bicep template |
| `main.bicepparam` | Deployment parameters (region: `francecentral`) |
| `deploy.sh` | End-to-end script: deploy infra → upload blob → generate SAS URL |

---

## Prerequisites

- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) ≥ 2.61
- Contributor + User Access Administrator on the target subscription (or resource group)
- WSL / Linux / macOS shell

---

## Deploy

```bash
az login
./deploy.sh
```

The script will:

1. Create resource group `rg-dlpevidence-test` in `francecentral`
2. Validate then deploy the Bicep template (~10–15 min, App Gateway provisioning)
3. Assign `Storage Blob Data Contributor` and `Storage Blob Delegator` to the signed-in user
4. Upload `prisma.txt` (content: `Prisma Downloaded`) to the `prisma-access` container
5. Generate a **user-delegation SAS URL** valid for 24 hours and print two URLs:

```
1) Direct HTTPS URL (baseline):
   https://sadlpevidencetest.blob.core.windows.net/prisma-access/prisma.txt?<SAS>

2) Via App Gateway URL (replicates the DLP redirect — open in Edge):
   http://appgw-dlpevidence.francecentral.cloudapp.azure.com/prisma-access/prisma.txt?<SAS>
```

Paste either URL into Edge — the file downloads immediately with no additional login.

---

## Key configuration detail

In `main.bicep`, the Backend HTTP Settings block contains:

```bicep
backendHttpSettingsCollection: [
  {
    name: 'httpsettings-storage'
    properties: {
      port: 443
      protocol: 'Https'
      // Override Host header with the backend FQDN (storage account hostname).
      // Without this, SAS signature validation fails (AuthenticationFailed).
      pickHostNameFromBackendAddress: true
      ...
    }
  }
]
```

The same flag must be set on the **production** App Gateway (`appgw-sandbox-dlpevidence`) to resolve the customer issue.

---

## Note on key-based authentication

This subscription enforces `KeyBasedAuthenticationNotPermitted` on storage accounts. The deploy script therefore uses **Entra ID authentication** throughout:

- Blob upload: `az storage blob upload --auth-mode login`
- SAS generation: `az storage blob generate-sas --auth-mode login --as-user` (user-delegation SAS)

A user-delegation SAS is self-contained and works in any browser without re-authentication, identical in behavior to an account-key SAS.
