# Changelog

All notable changes to this project will be documented in this file. See [commit-and-tag-version](https://github.com/absolute-version/commit-and-tag-version) for commit guidelines.

## [2.3.0](https://github.com/blackopsrepl/tokenmaxx/compare/v2.2.0...v2.3.0) (2026-10-14)


### Features

* **panel:** bounded bar drop-down surface instead of a screen overlay 1332b3f

## [2.2.0](https://github.com/blackopsrepl/tokenmaxx/compare/v2.1.0...v2.2.0) (2026-10-14)


### Features

* **panel:** labelled action lifecycle and narrow viewport 1329106

## [2.1.0](https://github.com/blackopsrepl/tokenmaxx/compare/v2.0.4...v2.1.0) (2026-10-12)

### Features

* **panel:** mac-bar modal — no scrim, no forced focus; streamlined badges 340c9f7

## [2.0.4](https://github.com/blackopsrepl/tokenmaxx/compare/v2.0.3...v2.0.4) (2026-10-09)


### Bug Fixes

* **ollama:** read account allowance from the balance endpoint 2559622

## [2.0.3](https://github.com/blackopsrepl/tokenmaxx/compare/v2.0.2...v2.0.3) (2026-10-09)


### Bug Fixes

* **runtime:** keep pinned provider across daemon refreshes c67262b

## [2.0.2](https://github.com/blackopsrepl/tokenmaxx/compare/v2.0.1...v2.0.2) (2026-09-30)


### Bug Fixes

* **ui:** restore executable lookup for panel actions c85b4e4

## [2.0.1](https://github.com/blackopsrepl/tokenmaxx/compare/v2.0.0...v2.0.1) (2026-09-30)


### Bug Fixes

* **runtime:** drain subprocess output before waiting for exit e2c6764

## [2.0.0](https://github.com/blackopsrepl/tokenmaxx/compare/v1.8.2...v2.0.0) (2026-09-30)


### ⚠ BREAKING CHANGES

* CLI, config path, env var names, and install paths
all change; pre-rebrand installs need the one-time migration in
docs/installation.md

### Features

* rebrand CodexBar as TokenMaxx 5d76c57


### Bug Fixes

* **config:** seed config init from the legacy config and persist remapped paths 3b67101
* **runtime:** import legacy state files once on first state-dir creation 7e66c0a

## [1.8.2](https://github.com/blackopsrepl/codexbar-sway/compare/v1.8.1...v1.8.2) (2026-09-29)


### Bug Fixes

* **ui:** draw icon glyphs in the icon font, not a text-font fallback 1466ee2

## [1.8.1](https://github.com/blackopsrepl/codexbar-sway/compare/v1.8.0...v1.8.1) (2026-09-29)


### Bug Fixes

* **ui:** keep the peak marker inside the card's content edge 178adcb

## [1.8.0](https://github.com/blackopsrepl/codexbar-sway/compare/v1.7.0...v1.8.0) (2026-09-29)


### Features

* **ui:** tighten panel chrome on short screens c0e0f32


### Bug Fixes

* **peak:** name the current rate period in the static peak fields 8a192e2
* **ui:** bind the overview peak tooltip to its own hover area ed2c6b0
* **ui:** close the panel when the dimmed backdrop is clicked 96d8c7a
* **ui:** keep every provider in the rail reachable on short screens d25ec49
* **ui:** keep peak badges alive when compiled timelines are absent 3dad521
* **ui:** run every queued bar command instead of the latest 8e98285
* **ui:** scroll the history view and pin the peak view contract a080e01

## [1.7.0](https://github.com/blackopsrepl/codexbar-sway/compare/v1.6.3...v1.7.0) (2026-09-28)


### Features

* **local-usage:** count Hermes usage cumulatively with the CLI logs 7af5367
* **ui:** label which stores feed each provider's local usage 4f81391

## [1.6.3](https://github.com/blackopsrepl/codexbar-sway/compare/v1.6.2...v1.6.3) (2026-09-27)


### Bug Fixes

* **config:** write config atomically so readers never see a torn file ff57852
* **ui:** put the overview peak glyph on the title line cbfc5d7
* **ui:** render the overview peak as a compact inline glyph 024ab8c

## [1.6.2](https://github.com/blackopsrepl/codexbar-sway/compare/v1.6.1...v1.6.2) (2026-09-27)


### Bug Fixes

* **ui:** keep the overview peak label visible in narrow cards b8a2cb1

## [1.6.1](https://github.com/blackopsrepl/codexbar-sway/compare/v1.6.0...v1.6.1) (2026-09-27)


### Bug Fixes

* **peak:** resolve peak windows in local time and at exact boundaries def5d57
* **ui:** resolve peak state live from compiled timelines 50b1294

## [1.6.0](https://github.com/blackopsrepl/codexbar-sway/compare/v1.5.0...v1.6.0) (2026-09-27)


### Features

* **peak:** declare vendor peak/off-peak rate schedules 75efa70
* **ui:** surface peak/off-peak state per model 7523818

## [1.5.0](https://github.com/blackopsrepl/codexbar-sway/compare/v1.4.3...v1.5.0) (2026-09-27)


### Features

* **ollama:** add Ollama Cloud quota provider 2f75d5f
* **ollama:** read Ollama Cloud local usage from the OpenCode database 0a1aaf0
* **omarchy:** mount the Waybar chip as an Omarchy shell bar module c63a197
* **ui:** follow the active Omarchy theme 329950b


### Bug Fixes

* **install:** ship runtime/omarchy.rb in the install manifest 687bb5e
* **omarchy:** reject out-of-range bar module indexes 0165a7e
* **omarchy:** reject unused and conflicting placement flags 1ccc8b4
* **ui:** keep distinct heatmap fill tiers under Omarchy themes e8c2405
* **ui:** keep the overview usable on small screens 3836ab9

## [1.4.3](https://github.com/blackopsrepl/codexbar-sway/compare/v1.4.2...v1.4.3) (2026-09-17)


### Bug Fixes

* **ui:** keep heatmap peak label inside the stats line 809b8ea

## [1.4.2](https://github.com/blackopsrepl/codexbar-sway/compare/v1.4.1...v1.4.2) (2026-09-17)


### Bug Fixes

* **ui:** stop heatmap stats truncating at panel width b38e70b

## [1.4.1](https://github.com/blackopsrepl/codexbar-sway/compare/v1.4.0...v1.4.1) (2026-09-17)


### Features

* **ui:** add cumulative token heatmap to Overview 47a6c8c

## [1.4.0](https://github.com/blackopsrepl/codexbar-sway/compare/v1.3.0...v1.4.0) (2026-09-17)


### Features

* **ui:** make heatmap dual-metric and polish panel motion 55cedb7


### Bug Fixes

* **ui:** reduce heatmap to one fill ramp and a compact band 2e9b7a2

## [1.3.0](https://github.com/blackopsrepl/codexbar-sway/compare/v1.2.5...v1.3.0) (2026-09-17)


### Features

* **ui:** square the panel and add a token usage heatmap c95aa71

## [1.2.5](https://github.com/blackopsrepl/codexbar-sway/compare/v1.2.4...v1.2.5) (2026-09-16)


### Bug Fixes

* **history:** re-merge local usage for every scanned day 41a0a12

## [1.2.4](https://github.com/blackopsrepl/codexbar-sway/compare/v1.2.3...v1.2.4) (2026-09-16)


### Bug Fixes

* **local-usage:** attribute Codex and Claude local usage to models 2fbfdae

## [1.2.3](https://github.com/blackopsrepl/codexbar-sway/compare/v1.2.2...v1.2.3) (2026-09-16)


### Bug Fixes

* **local-usage:** scope OpenCode Go totals to the opencode-go provider 37b6816

## [1.2.2](https://github.com/blackopsrepl/codexbar-sway/compare/v1.2.1...v1.2.2) (2026-09-14)


### Features

* **zai:** read zai-routed local usage from the opencode database 2b50fc0


### Bug Fixes

* **opencode:** label the provider OpenCode Go edcb0fa

## [1.2.1](https://github.com/blackopsrepl/codexbar-sway/compare/v1.2.0...v1.2.1) (2026-09-14)


### Bug Fixes

* **presenter:** give every provider an equivalent overview summary 7d3ce02

## [1.2.0](https://github.com/blackopsrepl/codexbar-sway/compare/v1.1.1...v1.2.0) (2026-09-14)


### Features

* **zai:** add Z.ai GLM Coding Plan provider 64b13ab


### Bug Fixes

* **history:** retain consistent history across window and model providers 2619786
* **quickshell:** compact the overview display indicator 80f1d42
* **quickshell:** size history tiles from the layout, not their own grid 6b1bce7

## [1.1.1](https://github.com/blackopsrepl/codexbar-sway/compare/v1.1.0...v1.1.1) (2026-09-14)


### Bug Fixes

* **quickshell:** keep history tiles in fixed columns 7bc30fb
* **quickshell:** stop rewriting ui state on adapter updates 4dc4d3c

## [1.1.0](https://github.com/blackopsrepl/codexbar-sway/compare/v1.0.2...v1.1.0) (2026-09-14)


### Features

* **opencode:** add OpenCode Go quota integration 130cb5e


### Bug Fixes

* **gemini:** surface quota API error details e90d23c

## [1.0.2](https://github.com/blackopsrepl/codexbar-sway/compare/v1.0.1...v1.0.2) (2026-08-25)


### Bug Fixes

* **check:** isolate smoke runtime state 6cf9ce7
* **codex:** adapt quota collection to current app server 34a1600
* **codex:** expose unavailable five-hour quota b4c3b01
* **codex:** remove fabricated quota placeholders c291339
* **codex:** restore truthful missing-window state e1ec596
* **quickshell:** verify the supervised process ea1798e

## [1.0.1](https://github.com/blackopsrepl/codexbar-sway/compare/v1.0.0...v1.0.1) (2026-05-16)


### Bug Fixes

* **cli:** refresh auxiliary snapshots c6e9ddc

## [1.0.0](https://github.com/blackopsrepl/codexbar-sway/compare/v0.1.1...v1.0.0) (2026-05-16)


### Features

* **gemini:** preserve model-level quota and usage 9d3e533
* **ui:** center and harden the QuickShell modal ea28c8e


### Bug Fixes

* **cli:** keep provider activation local 69468d5
* **ui:** keep modal header actions in bounds d858f0d

## 0.1.1 (2026-05-16)


### Features

* establish CodexBar Linux release baseline 201a896
* **runtime:** add auxiliary quota intelligence 94ee4d4
* **ui:** add tabbed QuickShell quota panel c89ca1e


### Bug Fixes

* **providers:** restrict refreshed credential files 9d6a5bd
