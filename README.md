# Admin App Installation Scripts

This repository contains scripts to help make installing the Ed-Fi Admin App (v4 and above) easier to install

## Contents

- [quick-start/](quick-start/README.md) — Global Admin Quick Start: provisions
  a machine (service-account) client, a team, an environment, and ODS instances
  through the Admin App API so a global administrator can sign in and go
  straight to managing ODS instances, and copies the built-in claimsets in
  EdFi_Security under an `AA` prefix so they can be assigned to applications.
  Configure a `.env` file and run `run.ps1`; `cleanup.ps1` tears it all down.
  Full walkthrough:
  [Global Admin Quick Start on docs.ed-fi.org](https://docs.ed-fi.org/reference/admin-app/user-guide/global-admin-quick-start).

## Legal Information

Copyright (c) 2021 Ed-Fi Alliance, LLC and contributors.

Licensed under the [Apache License, Version 2.0](LICENSE) (the "License").

Unless required by applicable law or agreed to in writing, software distributed
under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
CONDITIONS OF ANY KIND, either express or implied. See the License for the
specific language governing permissions and limitations under the License.

See [NOTICES](NOTICES.md) for additional copyright and license notifications.
