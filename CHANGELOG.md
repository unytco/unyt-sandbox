# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.46.0]

### Updated

- Updated to use vanilla unyt UI

## [0.45.0]

### Added

- DNA: CodeTemplate, Lane, and SmartAgreement added PermissionSpaces [#239](https://github.com/unytco/unyt-app/pull/239)
  - New PermissionSpace enum: Global, Lane, Default
  - Permission validation trait with create/update checks against global and lane definitions
- DNA: DataBlob discoverable using tags and added permissions spaces [#239](https://github.com/unytco/unyt-app/pull/239)
  - Breaking change: create_data_blob expects new DataBlob struct with optional doc_def_hash field
  - DataBlob now includes version field (semver::Version) for versioning support
- DNA: DocDef entry type for document schema definitions [#239](https://github.com/unytco/unyt-app/pull/239)
  - New APIs: `create_doc_def`, `get_doc_def`, `get_all_my_doc_defs`, `get_data_blobs_for_doc_def`
  - DocDef entries include `json_schema`, `content_schema`, and `tags` for discoverability
  - DataBlobs can reference a DocDef via optional `doc_def_hash` field for validation
  - Automatic linking: DataBlobs are linked to their DocDef on creation (via DocDefToDataBlob link)
  - DocDefs are immutable (cannot be updated after creation)
  - DocDef-to-DataBlob links cannot be deleted (ensures data integrity)
  - New LinkTypes: `PathToDocDef`, `DocDefToDataBlob`

### Updated

- DNA: Struct changes [#239](https://github.com/unytco/unyt-app/pull/239)
  - GlobalDef refactored to use LaneDefinition as lane_def
  - LaneDef service_units changed from Vec<UnitIndex> to UnitIndexMap (BTreeMap<u8, ActionHash>)
  - Breaking change API: initialize_global_definition now expects InitializeGlobalDefinition struct
    - Includes global_definition and optional new_unit_definitions fields
    - Automatically creates and maps unit definitions during initialization
- DNA: validate all Input rules [#239](https://github.com/unytco/unyt-app/pull/239)
  - New validate_input_rules method in SmartAgreement validates all instruction types (Fixed, Query, ExecutorProvided, ProvidedBy, Custom)
  - Improved RAVE validation with is_credit_check_agreement and is_enforced_agreement methods and removed the need for the `__system` or `_lane`
  - Breaking change: CustomInstructions enum renamed to NonValidatedQuery
- DNA: execution will limit consumable links processed to 256 [#239](https://github.com/unytco/unyt-app/pull/239)
  - Prevents excessive link processing during agreement execution
- DNA: Breaking change: Renaming
  - SAVED to RAVE [#239](https://github.com/unytco/unyt-app/pull/239)
  - ServiceNetwork to Lane [#240](https://github.com/unytco/unyt-app/pull/240)
  - update_global_units to update_unit_def [#240](https://github.com/unytco/unyt-app/pull/240)
- DNA: Security review feedback: import rave_engine to coordinator from the integrity zome [#240](https://github.com/unytco/unyt-app/pull/240)
- DNA: Agent check is removed from the validation and an API check_agent_exist can be used by UI [#248](https://github.com/unytco/unyt-app/pull/248)

## [0.44.0]

### Updated

- holochain bumped to v0.6.0-dev32 and advanced network config `tx5Transport:timeoutS` 30sec
- Updated tauri menu options

## [0.43.0]

### Added

- UI: rideshare tauri fetching
- UI: move dna hash from footer to agent settings
- UI: zome calls are sequenced
- DNA: get_all_notification_links that lets you just get links and updated other endpoints to support just loading records [#]
- DNA: Transaction return_type for Accepts returns source [#237](https://github.com/unytco/unyt-app/pull/237)
- DNA: ea_id included in parked link notification links
- UI: code templates and lanes primarily use signal store
- UI: code templates, agreements and lanes never auto-refresh; add user manual refresh
- UI: disable interactions during accept and reject
- UI: add accept all button
- UI: include relevant agreement details in collected history item
- UI: display exclamation mark on credit limit if last call returned error
- UI: handle accept transaction timeout by notifying user and checking twice for illusive success

## [0.42.0]

### Added

- UI: incorporated the domino pips back with colors based on the unit type
- UI: Example agreements that users cannot edit or interact with
- DNA: validation check to not double spend on the same invoice and checks that the spend timestamp is after the invoice [#224](https://github.com/unytco/unyt-app/pull/224)
- UI: Agreements fetch from store
- UI: Contacts modal has unified search and address entry
- UI: Change fetch timers
- DNA: Parked and ParkedSpend now include role_display_name
- UI: Hide notes and action buttons on transactions view if screen is too small
- UI: Use 'ago' for transactions view and history view instead of timestamp
- UI: VITE_IS_RIDESHARE_RELEASE that enables a new modal that helps interaction with a custom rideshare agreements [#231](https://github.com/unytco/unyt-app/pull/231)
- UI: ability to select specific transaction when execute_rave or accept_paying_parked_invoice [#232](https://github.com/unytco/unyt-app/pull/232)

### Updated

- UI: Agent Overview balance and credit modal updated to be appropriately alined
- UI: Agreement and CodeTemplate Copy to create a new modal adds a prefix to title to have it be unique and suggest a change
- DNA: updated GlobalDefinition to have everything that the LaneDefinition contains [#230](https://github.com/unytco/unyt-app/pull/230)
- DNA: get_my_current_applied_credit_limit can be run with GetStrategy [#230](https://github.com/unytco/unyt-app/pull/230)
- UI: rideshare tauri fetching
- UI: rideshare increase auto zoom and added clear button on rideshare-modal

## [0.40.0]

### Added

- UI: Act as executor shows up only when your the executor [#220](https://github.com/unytco/unyt-app/pull/220)
- SmartAgreements lib: clean up naming to prep for release [#220](https://github.com/unytco/unyt-app/pull/220)
- UI: able to handle inputs required for aggregate executable agreements [#220](https://github.com/unytco/unyt-app/pull/220)
- UI: updated error handling from smart agreement executions [#220](https://github.com/unytco/unyt-app/pull/220)
- SmartAgreement lib: Updated logic for aggregate request [#220](https://github.com/unytco/unyt-app/pull/220)
- DNA: Update to holochain v0.6.0-dev.27 [#220](https://github.com/unytco/unyt-app/pull/220)
- UI: Smart Agreement search bar find by ID [#220](https://github.com/unytco/unyt-app/pull/220)
- DNA: get_all_smart_agreement returns status fulfilled [#220](https://github.com/unytco/unyt-app/pull/220)
- UI: Agrement Actions show separate list of fulfilled agrements [#220](https://github.com/unytco/unyt-app/pull/220)

## [0.39.0]

### Added

- UI: Sentry logging updated to only log zome_calls and track specific sucess calls [#216](https://github.com/unytco/unyt-app/pull/216)
- UI updates: [#217](https://github.com/unytco/unyt-app/pull/217)
  - improved error messages
  - watched items do not carry over between versions
- DNA: register agent that joins network for the BlockExplore to find and get_agent_status that will return `AgentStatus`[#218](https://github.com/unytco/unyt-app/pull/219)

## [0.38.0]

### Added

- Add local-first fetch options via ZomeFnInput wrapper to the following functions: [#209](https://github.com/unytco/unyt-app/pull/209)
  - get_code_templates_by_folder
  - search_code_template
  - search_smart_agreement
  - get_all_smart_agreements
- Add local-first fetch options via strategy: Option<GetStrategy> field to the following functions:
  - get_actionable_transactions
  - get_pending_transactions
  - get_incoming_raves
  - get_sorted_requests_to_spend
  - get_requests_to_execute_agreements
  - get_all_lane
- UI: Add initial local-first fetch to applicable signal stores and use VITE_ZERO_ARC=true to disable [#209](https://github.com/unytco/unyt-app/pull/209)
- UI: TroubleShooting tools

### Updated

- UI: loading screen centers any logo
- intergate ui-switcher with the white-lable UI [#211](https://github.com/unytco/unyt-app/pull/211)
- removed agent_details from happ bundle [#213](https://github.com/unytco/unyt-app/pull/213)
- DNA: Allocation needs to return a vec of sources, Now the allocated amounts to the receiver can be from multiple sources(i.e multiple ParkedLinks) [#214](https://github.com/unytco/unyt-app/pull/214)
- Bug: fixed notes not transferring between transaction causing users to not see the initial note that was sent
- App Update to work run on holochain `v0.6.0-dev.23`

## [0.37.0]

### Added

- update pkg to include zero arc release

## [0.36.0]

### Updated

- UI: Transaction model should does not let you create a transaction with multiple of the same unit
- Bug: watch list should show the transaction even if its not able to get the state for it
- UI: excessive contacts, no need to scroll to add
- UI: Sidebar defaults to open on app startup

## [0.35.0]

### Added

- advanced filters for must get query instructions for smaller input values [#208](https://github.com/unytco/unyt-app/pull/208)

### Updated

- optimized dynamic credit limit implementaion [#208](https://github.com/unytco/unyt-app/pull/208)

## [0.34.0]

### Updated

- added workflow for depositor
  - Oracle can create parked invoice
  - bridge agent can credit adjust
  - added carry forwards
  - bridge agreement bridge agent create a spend link, and original client can collect
- fix json validation of schema to appropriately validation required fields, and felids that can be multiple types
- resurrect the Dev UI to be ready to continue prototyping building on
- RAVE output updated to include rejected and redacted links [#]
- Updated endpoint to create Lanes
- remove the need for sales agent and purchase and redemption agreements
- UI: renamed lit-2 to white-label
- UI: updates for v0.33
- DNA: Check that the base unit cannot be negative on a transaction [#203](https://github.com/unytco/unyt/pull/203)
- Lib: added new tags that will be used in the UI [#205](https://github.com/unytco/unyt/pull/205)
- Update holochain to v0.5.6 [#206](https://github.com/unytco/unyt/pull/206)

## [0.33.0]

### Added

- Updated kitsune2

## [0.32.0]

### Added

- Tauri: Fixed the windows release
- Tauri: updater plugin
- Tauri: `iroh` networking stats
- UI: added a loading page for the asyn implementation of the new pkg that fixed windows

## [0.31.0]

### Updated

- UI: Smoother data fetching
- UI: New interaction modal
- UI: Bug fixes & formatting
- UI: Move unytStore to connectionService
- UI: Add sales agent badge to contact-label
- UI: Add agreement title to interaction note

## [0.30.0]

### Updated

- UI: export button for summary page [#197](https://github.com/unytco/unyt/pull/197)
- SA: fix circulo smart agreement [#197](https://github.com/unytco/unyt/pull/197)
- UI: export returns accrued fee and sa's title [#197](https://github.com/unytco/unyt/pull/197)
- UI: update agreement view to show expected inputs per role

## [0.29.0]

### Updated

- DNA: Update `code_templates` to define `one_time_run` and `aggregate_execution` [#192](https://github.com/unytco/unyt/pull/192)
- DNA: Added Transformer to the HdiCall [#192](https://github.com/unytco/unyt/pull/192)
- UI: Sentry reports package version
- UI: laneService uses connectionService to call zomes
- UI: .env variable VITE_SILENCE_SENTRY silences sentry reporting
- UI: Change color picker to shoelace default
- UI: Modify lane wizard according to feedback
- UI: Get app name from .env variable VITE_APP_NAME https://github.com/unytco/unyt/pull/194
- UI: Allow code templates to select one_time_run and aggregate_execution https://github.com/unytco/unyt/pull/194
- UI: .env variable VITE_IS_CIRCULO_RELEASE to hide some components and switch default credit limit to dynamic credit [#195](https://github.com/unytco/unyt/pull/195)
- UI: export button for summary page [#]
- SA: fix circulo smart agreement [#]
- UI: export returns accrued fee and sa's title [#]

## [0.28.0]

> failed release

## [0.27.0]

### Added

- UI uses Sentry to report errors [#189](https://github.com/unytco/unyt/pull/189)

### Updated

- DNA: compatable with holochain v0.5.5 [#190](https://github.com/unytco/unyt/pull/190)
- UI: replace titles with tooltips [#189](https://github.com/unytco/unyt/pull/189)
- UI: Handle Error messages [#189](https://github.com/unytco/unyt/pull/189)

## [0.26.0]

> broken release

## [0.25.0]

### Changed

- validation: updated fee_collection check is not needed when fees is set to 0 [#186](https://github.com/unytco/unyt/pull/186)

## [0.24.0]

### Changed

- hash bump

## [0.23.0]

### Changed

- rename app from domino to unyt [#185](https://github.com/unytco/unyt/pull/185)

## [0.22.0]

### Changed

- Update `get_sorted_requests_to_spend` and `get_requests_to_execute_agreements` to return just a `Vec<Transaction>` and it includes a new tx_state `GroupedParked` [#183](https://github.com/unytco/unyt/pull/183)
- Fixed the ui's ability to create agreement with authorized roles [#183](https://github.com/unytco/unyt/pull/183)
- bug fix: accept button shows double [#184](https://github.com/unytco/unyt/pull/184)
- UI: init script fee trigger updated to `99999999` [#184](https://github.com/unytco/unyt/pull/184)

## [0.21.0]

### Added

- DNA: new endpoint get_smart_agreement_all_versions and get_code_template_all_versions [#180](https://github.com/unytco/unyt/pull/180)
- Changed role to pass the amount that they provide as <role_id>\_allocation in the smart agreement [#182](https://github.com/unytco/unyt/pull/182)

### Changed

- UI updated to handle and mange views depending on the transaction type [#]()

## [0.20.0]

### Changed

- new hash space, with new UI updates based on team testing

## [0.19.0]

### Added

- **Role-Based Input Rules in SmartAgreements:** `SmartAgreement` input rules now reference roles defined in the `CodeTemplate`, ensuring a clear and verifiable link between the two. This change streamlines validation by delegating role expectation management to the `CodeTemplate`. [#169](https://github.com/unytco/unyt/pull/169)
- **Role Definitions in `CodeTemplate`:** The `agreement_definition_input` in `CodeTemplate` now defines roles and their `consumed_link` expectation. This centralizes role management, simplifying `SmartAgreement` validation. [#169](https://github.com/unytco/unyt/pull/169)
- **Validation for `hdi_call` Inputs in RAVE:** `RAVE` now validates that inputs using `hdi_call` collect the correct values, improving data integrity and ensuring that `hdi_call` operations are properly validated.
- **Enhanced Validation for `unyt_allocation` in RAVE:** `RAVE` now validates that the source of a `unyt_allocation` is not reused, preventing duplicate spending and ensuring that all allocations are unique.[#169](https://github.com/unytco/unyt/pull/169)
- CodeTemplateExt and SmartAgreementExt returns a vec of tags [#171](https://github.com/unytco/unyt/pull/171)
- `ignore_notification` zome call to dismiss transaction notifications [#172](https://github.com/unytco/unyt/pull/172)
- Simple transaction signaling to use `post_commit` hook, providing more reliable and detailed real-time updates to all parties involved in a transaction. [#173](https://github.com/unytco/unyt/pull/173)
- DNA: `get_all_my_smart_agreements` added to get smart_agreements created by this agent itself [#176](https://github.com/unytco/unyt/pull/176)
- `SmartAgreementExt` updated to return version [#176](https://github.com/unytco/unyt/pull/176)
- DNA: added endpoint to get status of a tx or agreement based on hash [#177](https://github.com/unytco/unyt/pull/177)

### Changed

- **Breaking Change:** `SmartAgreement` no longer defines its own role expectations and instead relies on the `CodeTemplate` to manage them. This change simplifies the `SmartAgreement` structure and centralizes role management.[#169](https://github.com/unytco/unyt/pull/169)
- **Refined `hdi_call` Support:** `SmartAgreement` input rules now exclusively support `hdi_calls` to ensure all operations can be validated on the DHT. This improves security and data consistency.
- `create_smart_agreement` and `create_code_template` payloads updated to not expect a separate `tag` parameter. The `tags` are now included in the `SmartAgreement` and `CodeTemplate` structs. [#174](https://github.com/unytco/unyt/pull/174)
- Tags are now returned as `TagFilter` objects instead of strings, providing more structured data. [#174](https://github.com/unytco/unyt/pull/174)
- When updating `CodeTemplate` or `SmartAgreement` tags, old tags are removed and new tags are added, ensuring the entry's tags are always up-to-date. [#174](https://github.com/unytco/unyt/pull/174)
- updated get_code_templates_by_tags to get_code_templates_by_folder
- updated get_all_agents_code_templates to get_my_code_templates

## [0.18.0]

### Changed

- new release flow using p2p-shipyard
- Switching holochain networking to use iroh

## [0.17.0]

### Changed

- renaming variables in the code base to match latest naming convention [#165](https://github.com/unytco/unyt/pull/165)
  - Pieces > Units
  - Piece > Unit
  - pieces > units
  - piece > unit
  - SwimLane > ServiceNetwork
  - swimLane > serviceNetwork
  - swim_lane > service_network
  - swimlane > servicenetwork
  - pool > global
  - Pool > Global
  - RAVE > RAVE
  - rave_lib > smart_agreement_library
  - executable_agreement > smart_agreement
  - ExecutableAgreement > SmartAgreement
  - SLSpecialAgents > CommonSpecialAgents
  - SLRAVEAgreements > CommonRAVEAgreements
- code-templates tagged [#166](https://github.com/unytco/unyt/pull/166)
- prep for shipyard releases [#167](https://github.com/unytco/unyt/pull/167)
- compatible with holochain v0.5.4 [#168](https://github.com/unytco/unyt/pull/168)

## [0.16.0]

### Changed

- **Breaking Change:** create_smart_agreement payload updated to accept tags [#](https://github.com/unytco/unyt/pull/)
  - New endpoints: search_smart_agreement and get_all_smart_agreements
- New Home UI that wraps all the ui skins [#]
- Handle dynamic credit RAVE, hdk::query handled in instructions [#162](https://github.com/unytco/unyt/pull/162)
- **Breaking Change:** dna bumped to run on holochain v0.5.3
- piecework_cli updated to unyt_cli for latest work [#164](https://github.com/unytco/unyt/pull/164)

## [0.15.0]

### Changed

- New field theme that is expected to be a hex string in LaneBasicProperties [#145](https://github.com/unytco/unyt/pull/145)
- Unyt: Data Migration for version updates [#147](https://github.com/unytco/unyt/pull/147)
- UI: basic and advanced mode, new request spend modals [#149](https://github.com/unytco/unyt/pull/149)
- code-template versioning [#152](https://github.com/unytco/unyt/pull/152)
- **Breaking Change:** optimize memory usage by storing units as maps instead of Vec's [#151](https://github.com/unytco/unyt/pull/151)
- **Breaking Change:** create_smart_agreement payload updated to accept tags [#](https://github.com/unytco/unyt/pull/)

## [0.14.2]

### Fixed

- Fix UI bug on timestamp on completed transaction table

## [0.14.1]

### Changed

- Fix UI bug on Effective start date display correctly

## [0.14.0]

### Changed

- DNA upgraded to run on holochain v0.5.2 [#133](https://github.com/unytco/unyt/pull/133)
- DNA: expose endpoitns to be able to create service units on lane gen [#134](https://github.com/unytco/unyt/pull/134)
- bug: progenitor created check updated in validate [#134](https://github.com/unytco/unyt/pull/134)
- Validation document added [#134](https://github.com/unytco/unyt/pull/134)
- updated docs and ui naming updates [#135](https://github.com/unytco/unyt/pull/135)
- improved code comments [#136](https://github.com/unytco/unyt/pull/136)
- lane endpoints to call progenitor for approval [#144](https://github.com/unytco/unyt/pull/144)

## [0.13.0]

### Added

- New common `Transaction` type for improved UI experience and consistency [#129](https://github.com/unytco/unyt/pull/129)
  - Introduces standardized transaction states: pending, actionable, and completed
  - Replaces multiple transaction types with a unified interface
- DNA: agent_details for managing personal address book [#130](https://github.com/unytco/unyt/pull/130)

### Changed

- Changed API endpoints to use the common `Transaction` type: [#129](https://github.com/unytco/unyt/pull/129)
  - `get_sorted_requests_to_spend`: Now returns `Vec<Vec<Transaction>>`
  - `accept_paying_parked_invoice`: Now uses `AcceptPayingInvoices` type
  - `get_requests_to_execute_agreements`: Now uses `ExecutionRequests` type
  - `get_parked_spend`: Now returns `Vec<Transaction>`
  - `get_parked_links`: Now returns `Vec<Transaction>`
  - `get_incoming_raves`: Now returns `Vec<Transaction>`
  - `collect_from_rave`: Now returns `Transaction`
  - `get_all_my_executed_raves`: Now returns `Vec<Transaction>`
- Changed Language only on dev-hub [#132](https://github.com/unytco/unyt/pull/132)

### Removed

- `RAVEToCollect` type is deprecated in favor of the common `Transaction` type [#129](https://github.com/unytco/unyt/pull/129)

### Changed

- ActionTable component for improved transaction management [#129](https://github.com/unytco/unyt/pull/129)

## [0.12.0]

### Changed

- Defined common `Transaction` type for all actions[#124](https://github.com/unytco/unyt/pull/124)
- Documentation of zome calls[#124](https://github.com/unytco/unyt/pull/124)
- Testing: improved tests for credit checks [#125](https://github.com/unytco/unyt/pull/125)
- Added possible_actions to the `Transaction` type [#126](https://github.com/unytco/unyt/pull/126)
- Testing: improved tests for fees dropoff and collections [#127](https://github.com/unytco/unyt/pull/127)
- ui: bug fix on the parked spend form to parse the payload [#127](https://github.com/unytco/unyt/pull/127)
- ui: updated interact as button to show descriptions

## [0.11.0]

### Changed

- validation: reviewed validation for links [#118](https://github.com/unytco/unyt/pull/118)
- validation: credit check for sales-agent [#118](https://github.com/unytco/unyt/pull/118)
- create link from EA to RAVE to collect all the RAVE's that were executed for a EA [#118](https://github.com/unytco/unyt/pull/118)
- UI: create custom conversion sheets [#119](https://github.com/unytco/unyt/pull/119)
- upgraded UI workspace to maintain multiple UI skins [#121](https://github.com/unytco/unyt/pull/121)
- improved rave_engine with tests [#123](https://github.com/unytco/unyt/pull/123)

## [0.10.0]

### Changed

- revisiting validations [#112](https://github.com/unytco/unyt/pull/112)
- default role_name is always set to lower-case and ui displays as pascal case [#113](https://github.com/unytco/unyt/pull/113)
- ui: rave action buttons do not expect an executor if it already provided, and executor button does not show up if you are not the executor [#113](https://github.com/unytco/unyt/pull/113)
- data blob: ability to add a record that could be used to reference as an input in the RAVE[#114](https://github.com/unytco/unyt/pull/114)
- validate `_lane` RAVE's based on the lane rules [#115](https://github.com/unytco/unyt/pull/115)
- ui: clone and edit SmartAgreement [#115](https://github.com/unytco/unyt/pull/115)
- sales-agent: specific endpoints for purchase and redemption [#115](https://github.com/unytco/unyt/pull/115)
- ui: use custom sales-agent endpoints [#115](https://github.com/unytco/unyt/pull/115)
- documentation: added new architecture docs for purchase and redemption [#115](https://github.com/unytco/unyt/pull/115)

### Removed

- removed service_fees RAVE from CommonRAVEAgreements [#114](https://github.com/unytco/unyt/pull/114)

## [0.9.1]

### Changed

- ui: persist data on rave transaction models [#111](https://github.com/unytco/unyt/pull/111)

## [0.9.0]

### Changed

- code-template: update to allow updates [#82](https://github.com/unytco/unyt/pull/82)
- exported rave library into a git submodule [#83](https://github.com/unytco/unyt/pull/83)
- exported rave engine into a rust crate [#84](https://github.com/unytco/unyt/pull/84)
- fee-collection: use aggregate spend rave to collect fees [#86](https://github.com/unytco/unyt/pull/86)
- validation: check that fees owed is not higher than the fee trigger amount [#87](https://github.com/unytco/unyt/pull/87)
- update aggregate receive rave to \_\_system_transaction_fee_collection [#88](https://github.com/unytco/unyt/pull/88)
- ui: update code template table to show a dropdown arrow to expand the code template table [#89](https://github.com/unytco/unyt/pull/89)
- ui: add unclaimed balance to the ledger status [#89](https://github.com/unytco/unyt/pull/89)
- ux: add a toggle icon to the global display to expand the global display [#90](https://github.com/unytco/unyt/pull/90)
- ui: setup common styles for the interface [#90](https://github.com/unytco/unyt/pull/90)
- export rave instructions from the rave engine crate [#91](https://github.com/unytco/unyt/pull/91)
- create a client for the unyt app called `unyt_cli`
- SmartAgreement: add a new field `title` [#92](https://github.com/unytco/unyt/pull/95)
- ui: Persist Content in Agreement Interaction Modal(s) [#96](https://github.com/unytco/unyt/pull/96)
- ui: add a new field `title` to the SmartAgreement table [#97](https://github.com/unytco/unyt/pull/97)
- validation: credit limit needs to be checked with the appropriate global definition and if it has expired [#98](https://github.com/unytco/unyt/pull/98)
- ui: rename rave lib to code lib [#100](https://github.com/unytco/unyt/pull/100)
- rename: promise -> spend [#101](https://github.com/unytco/unyt/pull/101)
- rename global definition variable system_rave_agreement [#102](https://github.com/unytco/unyt/pull/102)
- transaction fees and trigger defined in global definition [#104](https://github.com/unytco/unyt/pull/104)
- ui: display current applied credit limit for user [#105](https://github.com/unytco/unyt/pull/105)
- rename application to unyt [#106](https://github.com/unytco/unyt/pull/106)
- new sn implementation [#107](https://github.com/unytco/unyt/pull/107)
- upgrading a new endpoint to get the current global definition [#108](https://github.com/unytco/unyt/pull/108)
- update holochain dependencies to use latest versions (v0.4.2) [#109](https://github.com/unytco/unyt/pull/109)
- SmartAgreements with roles to specify input rules [#110](https://github.com/unytco/unyt/pull/110)

## [0.8.0]

### Changed

- UI: updated to load rave library from rave library dir [#78](https://github.com/unytco/unyt/pull/78)
- RAVE library: added conditional forward and aggregate receive raves [#79](https://github.com/unytco/unyt/pull/79)
- validations: checks the output amount against the spendd amount [#79](https://github.com/unytco/unyt/pull/79)
- RAVE library: conditional forward check units transferred [#80](https://github.com/unytco/unyt/pull/80)
- UI: handles amount sign based on the endpoints used [#81](https://github.com/unytco/unyt/pull/81)

## [0.7.0]

### Changed

- add rhai helper functions for raves [#74](https://github.com/unytco/unyt/pull/74)
- add a Custom RAVE Instructions for inputs [#75](https://github.com/unytco/unyt/pull/75)

## [0.6.1]

### Changed

- ui: network sync checks for global definition and code templates required to start transactions [#73](https://github.com/unytco/unyt/pull/73)

## [0.6.0]

### Changed

- dna updates for multi unyt support [#65](https://github.com/unytco/unyt/pull/65)
- ui updates for multi unyt support [#66](https://github.com/unytco/unyt/pull/66)
- ui admin portal to setup global [#67](https://github.com/unytco/unyt/pull/67)
- direct transaction upgraded to support multiple unyts [#68](https://github.com/unytco/unyt/pull/68)
- endpoints to create an invoice auto updates the reference units to be negative [#70](https://github.com/unytco/unyt/pull/70)
- validation: check input and output against code_template schema [#71](https://github.com/unytco/unyt/pull/71)
- validation: check parked_spends unyt_allocation against rave outputs unyt_allocation [#72](https://github.com/unytco/unyt/pull/72)

## [0.5.0]

- broken release due to build issues in the kangaroo repo

## [0.4.0]

### Changed

- Ability to set a optional list of executors to an SmartAgreement [#50](https://github.com/unytco/unyt/pull/50)
- Ability to create a parked spend for multiple parked invoices [#51](https://github.com/unytco/unyt/pull/51)
- Update Example Code Templates documents [#51](https://github.com/unytco/unyt/pull/51)
- new endpoint to get sorted requests to spend to run aggregate spends [#51](https://github.com/unytco/unyt/pull/51)
- add init script to create templates and agreements in the global admin tab [#56](https://github.com/unytco/unyt/pull/56)
- update to include all RAVE actions to be triggered from the SmartAgreement Table [#58](https://github.com/unytco/unyt/pull/58)
- add/update validation rules [#61](https://github.com/unytco/unyt/pull/61)
  - code_template: check titles that can only be commited by the progenitor
  - remove the credit_limit_override from the DNA properties and move that logic based on the progenitor existence
  - accept validates ExecutionInstances
  - raves validates its executed code
- compatible with holochain v0.4.1 [#62](https://github.com/unytco/unyt/pull/62)

### Changed/Fixed

- `SendExecutorParkedInvoiceNotification` link to `SendExecutorParkedSpendNotification` [#49](https://github.com/unytco/unyt/pull/49)
- ui code template form reorder inputs boxs [#52](https://github.com/unytco/unyt/pull/52)
- ui upgrades that enables aggregate spends [#52](https://github.com/unytco/unyt/pull/52)
- Ability to execute a rave without a parked spend or parked invoice [#53](https://github.com/unytco/unyt/pull/53)
- bug: notification not showing for the request to spend in raves [#54](https://github.com/unytco/unyt/pull/54)
- update zfuel to 0.2.1 (type updated to u64) [#57](https://github.com/unytco/unyt/pull/57)
- standardization of RAVE outputs [#60](https://github.com/unytco/unyt/pull/60)
- ui: Actionable Transactions table for spends and invoices easier to interact with [#63](https://github.com/unytco/unyt/pull/63)

## [0.3.0]

### Changed

- build process in kangaroo

## [0.2.0]

### Changed

- bump for hashspace

## [0.1.3]

### Fixed

- credit_limit RAVE expects typo fix `claiming_agent_pubkey` [#46](https://github.com/unytco/unyt/pull/46)
- update admin tab to global admin and reorder [#47](https://github.com/unytco/unyt/pull/47)
- update Lane tab to update parent about Lanes existence [#47](https://github.com/unytco/unyt/pull/47)
- update ui to update counts when tables change [#47](https://github.com/unytco/unyt/pull/47)

## [0.1.2]

### Changed

- update app icons and hc-spin/holochain-client library [#44](https://github.com/unytco/unyt/pull/44)
- Update RAVE flow that removes parked_invoice and parked_spend dependencies on each other [#45](https://github.com/unytco/unyt/pull/45)
- remove parked_invoice_signature from code_template and payload from parked_invoice [#45](https://github.com/unytco/unyt/pull/45)

## [0.1.1]

### Changed

- implemented a credit-limit check for spends and parked-spends [#40](https://github.com/unytco/unyt/pull/40)
- update payment endpoints to check credit and auto apply credit RAVE [#41](https://github.com/unytco/unyt/pull/41)
- parked_invoice: change from Record to Link type && parked_spend uses executor as the target [#42](https://github.com/unytco/unyt/pull/42)
- ui credit_check on accept_transaction while accepting an invoice [#43](https://github.com/unytco/unyt/pull/43)

## [0.1.0]

### Changed

### Fixed

### Removed
