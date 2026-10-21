# Agent instructions

This repository has two ways to set up the Infracost Azure integration:

- The Terraform module: `main.tf`, `variables.tf`, `outputs.tf`, `version.tf` and `modules/`.
- The `az` CLI scripts in `scripts/`: bash in `scripts/linux/`, PowerShell in `scripts/windows/`.

Both must give the same result. Keep these three in line in the same pull request.

## When you change the Terraform module

Update the scripts in both `scripts/linux/` and `scripts/windows/` to match, if the change affects:

- A resource, role, role assignment, or the order of the steps.
- A default value, for example roles, resource group, storage account name, container, root path, lifecycle days, export name or export settings.
- A variable that has a script option.
- An output key. The setup scripts write the same keys as `outputs.tf`.
- An Azure API version.

Also update `scripts/README.md`: the options table, the "What the script creates" table, the flow diagrams and the preflight table.

## When you change a script

- Make the same change in the bash and the PowerShell script. Each step has the same name in both shells, for example `set_storage_account` and `Set-StorageAccount`, in the same order.
- Constants are in `scripts/linux/common.sh` and `scripts/windows/common.ps1`. Keep the values the same in both files.
- Each option has the same name in both shells, in kebab-case for bash and PascalCase for PowerShell, for example `--client-id` and `-ClientId`.
- If the change makes a script differ from the Terraform module, change the module too, or explain the difference in `scripts/README.md`.
- Update `scripts/README.md`, the bash `--help` text, the PowerShell comment-based help, and `scripts/examples/` if an option or step changes.
- Each function has a one-line comment above it that says its purpose. Use the same text in the bash and the PowerShell function.

## Versions

release-please bumps the version in `version.tf`, `scripts/linux/common.sh` and `scripts/windows/common.ps1` together. Do not change these versions by hand.

## Checks

Run these before you push:

```bash
terraform fmt -check -recursive
(cd scripts/linux && shellcheck -x -S style setup.sh teardown.sh)
shfmt -i 2 -ci -bn -d scripts/linux
pwsh -c 'Invoke-ScriptAnalyzer -Path scripts/windows -Recurse -Settings scripts/windows/PSScriptAnalyzerSettings.psd1'
```

Do a dry run of the changed script with `--dry-run` or `-DryRun`. Compare the `az` commands of the bash and the PowerShell script.
