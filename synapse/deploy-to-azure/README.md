# Synapse Link Infrastructure – Deploy to Azure

This folder contains the ARM template used by the **Deploy to Azure** button in the PracticePro 365 documentation.

## Files

| File | Purpose |
|------|---------|
| `main.bicep` | Source of truth. Edit this file to make infrastructure changes. |
| `main.json` | Compiled ARM template. This is what Azure actually deploys. **Do not edit directly.** |
| `createUiDefinition.json` | Portal UI definition for the Deploy to Azure wizard. |

## ⚠️ Important: Rebuilding main.json after changes

The **Deploy to Azure** button uses `main.json`, not `main.bicep`. After making any changes to `main.bicep`, you must recompile it:

```bash
az bicep build --file main.bicep --outfile main.json
```

Then commit both `main.bicep` and `main.json` together. If you forget this step, the portal will deploy the old version and your changes will have no effect.

### Prerequisites

- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) installed
- Bicep extension: `az bicep install` (or `az bicep upgrade` to update)
