# Changelog

## [0.6.1](https://github.com/infracost/terraform-azure-integration/compare/v0.6.0...v0.6.1) (2026-11-02)


### Documentation

* add early access banner and docs link to README ([#22](https://github.com/infracost/terraform-azure-integration/issues/22)) ([746245f](https://github.com/infracost/terraform-azure-integration/commit/746245f18d28e3a9ac852c2c89f54c2ad501d158))

## [0.6.0](https://github.com/infracost/terraform-azure-integration/compare/v0.5.0...v0.6.0) (2026-10-23)


### Features

* add az CLI setup and teardown scripts for Linux and Windows ([#18](https://github.com/infracost/terraform-azure-integration/issues/18)) ([beb811d](https://github.com/infracost/terraform-azure-integration/commit/beb811de8a4372cf9f7cf3feb7eff1947b25dbbd))


### Bug Fixes

* billing reader role ID in the PowerShell scripts ([#21](https://github.com/infracost/terraform-azure-integration/issues/21)) ([04af3ce](https://github.com/infracost/terraform-azure-integration/commit/04af3ce71b6c068cf68bca546151cab93ad08476))
* preflight and log output of the az CLI scripts ([#20](https://github.com/infracost/terraform-azure-integration/issues/20)) ([fb0d91f](https://github.com/infracost/terraform-azure-integration/commit/fb0d91fdbf11b72c7e7e5f25e086ca96a024d449))

## [0.5.0](https://github.com/infracost/terraform-azure-integration/compare/v0.4.1...v0.5.0) (2026-10-02)


### Features

* add billing_exports module for FOCUS cost export ([#15](https://github.com/infracost/terraform-azure-integration/issues/15)) ([325b29c](https://github.com/infracost/terraform-azure-integration/commit/325b29cf9739594f9282259908255bfb1a158aca))

## [0.4.1](https://github.com/infracost/terraform-azure-integration/compare/v0.4.0...v0.4.1) (2026-10-01)


### Bug Fixes

* remove billing permissions precondition that fails for billing account owners ([#14](https://github.com/infracost/terraform-azure-integration/issues/14)) ([b058554](https://github.com/infracost/terraform-azure-integration/commit/b058554bcd6a8f92da1f4b7a526dc2d7e1b7d98d))

## [0.4.0](https://github.com/infracost/terraform-azure-integration/compare/v0.3.0...v0.4.0) (2026-09-30)


### Features

* assign billing account reader role for EA and MCA ([#11](https://github.com/infracost/terraform-azure-integration/issues/11)) ([545597c](https://github.com/infracost/terraform-azure-integration/commit/545597c85bca0b3ecfc578718fbd2c3350a16061))


### Miscellaneous

* pin GitHub Actions to SHAs (FIX-831) ([#12](https://github.com/infracost/terraform-azure-integration/issues/12)) ([35b45c3](https://github.com/infracost/terraform-azure-integration/commit/35b45c31756db45b99d9e5efa9e60c1770ded934))

## [0.3.0](https://github.com/infracost/terraform-azure-integration/compare/v0.2.2...v0.3.0) (2026-09-28)


### Features

* add service_principal_owners variable ([#9](https://github.com/infracost/terraform-azure-integration/issues/9)) ([681dc00](https://github.com/infracost/terraform-azure-integration/commit/681dc0096f346e084925c8409346174130d8b731))

## [0.2.2](https://github.com/infracost/terraform-azure-integration/compare/v0.2.1...v0.2.2) (2026-09-28)


### Bug Fixes

* stop replacing role assignments on module version bumps ([#7](https://github.com/infracost/terraform-azure-integration/issues/7)) ([336e718](https://github.com/infracost/terraform-azure-integration/commit/336e718e011476f2dc753eab7688b5194ba2a185))

## [0.2.1](https://github.com/infracost/terraform-azure-integration/compare/v0.2.0...v0.2.1) (2026-09-28)


### Bug Fixes

* show service principal in enterprise applications ([#5](https://github.com/infracost/terraform-azure-integration/issues/5)) ([1246830](https://github.com/infracost/terraform-azure-integration/commit/12468309809222477cd170765bcb159e8bef4899))

## [0.2.0](https://github.com/infracost/terraform-azure-integration/compare/v0.1.0...v0.2.0) (2026-09-25)


### Features

* add service principal and management group role assignments ([#3](https://github.com/infracost/terraform-azure-integration/issues/3)) ([2b39ab6](https://github.com/infracost/terraform-azure-integration/commit/2b39ab67dd4407df3fbc879f48b1953518fe4157))

## 0.1.0 (2026-09-25)


### Miscellaneous

* add release-please versioning setup ([4f54fb2](https://github.com/infracost/terraform-azure-integration/commit/4f54fb2f51d58d8d9ecea18c0fabad4384f51a47))
