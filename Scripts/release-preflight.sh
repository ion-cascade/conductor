#!/bin/bash
# Run after preparing the debug test build, before live or full-suite qualification.
set -euo pipefail
cd "$(dirname "$0")/.."
exec swift test --disable-automatic-resolution --skip-build --no-parallel --filter 'SemanticOracleCensusTests|OperationRegistry|OperationCatalog|IndexBindingCensus|WorkflowSkillCatalog|HCGlobalInvariantTests|ChannelEQBandCatalogTests|OperationTraceCoverage|OperationParameterContract|ParameterContracts|StockInstrumentCatalog|ReleasePipelineContractTests'
