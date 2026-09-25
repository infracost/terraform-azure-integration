// Surfaced as the InfracostModuleVersion tag on every resource this module
// creates, so Infracost can detect which module version provisioned the role.
// Bumped automatically by release-please on each release.
locals {
  module_version = "0.1.0" # x-release-please-version
}
