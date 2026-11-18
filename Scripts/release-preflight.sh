#!/bin/bash
# Run after preparing the debug test build, before live or full-suite qualification.
set -euo pipefail
cd "$(dirname "$0")/.."
exec swift test --disable-automatic-resolution --skip-build --no-parallel --filter 'Census|Completeness|Invariant|OperationRegistry|OperationCatalog|WorkflowSkillCatalog|ChannelEQBandCatalogTests|OperationTraceCoverage|OperationParameterContract|ParameterContracts|StockInstrumentCatalog|ReleasePipelineContractTests|RetroSynth|midiExportPanel|FocusedApplicationOwnership|QualificationConductorReadsTests'
