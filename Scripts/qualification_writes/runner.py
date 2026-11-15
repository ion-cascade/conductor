"""Run operation-bound write recipes against one owned Mac release installation.

Run from the repository root with python3 -m Scripts.qualification_writes.runner.
The trusted fixture driver keeps site-specific launch and fixture paths out of the code.
"""

import argparse
from hashlib import sha256
import json
from pathlib import Path
import re
import runpy

from . import automation, insert_bypass, insert_preset, mixer, pattern_step
from . import region_edit, region_parameters, sidechain, stem_splitter


def one(recipe, operation):
    return lambda fixture: {operation: recipe(fixture)}


def switches(fixture):
    return {operation: mixer.qualify_mixer_switch(fixture.client, operation, fixture.project_path,
                                                  fixture.project_ref)
            for operation in mixer.COMMANDS}


def lane_recipe(lane):
    return lambda fixture: automation.qualify_automation(fixture, lane)


CASES = {
    "mixer": (switches, frozenset(mixer.COMMANDS)),
    "preset": (one(insert_preset.qualify_insert_preset, insert_preset.OPERATION),
               {insert_preset.OPERATION}),
    "bypass": (one(insert_bypass.qualify_insert_bypass, insert_bypass.OPERATION),
               {insert_bypass.OPERATION}),
    "region_edit": (one(region_edit.qualify_region_edit, region_edit.OPERATION),
                    {region_edit.OPERATION}),
    "region_parameters": (region_parameters.qualify_region_parameters,
                          {"project.set_region_gain", "project.set_region_fade"}),
    "volume": (lane_recipe("volume"), {"tracks.create_volume_automation_at_region_borders",
                                       "tracks.set_volume_automation_point"}),
    "pan": (lane_recipe("pan"), {"tracks.create_pan_automation_point", "tracks.set_pan_automation_point"}),
    "splitter": (one(stem_splitter.qualify_stem_splitter, stem_splitter.OPERATION),
                 {stem_splitter.OPERATION}),
    "pattern": (one(pattern_step.qualify_pattern_step, pattern_step.OPERATION),
                {pattern_step.OPERATION}),
    "sidechain": (one(sidechain.qualify_sidechain, sidechain.OPERATION), {sidechain.OPERATION}),
}


def check_identity(observed, version, digest):
    if (observed.get("version") != version or observed.get("sha256") != digest
            or not str(observed.get("binary", "")).startswith("/")):
        raise RuntimeError(f"The active bridge does not match the expected build: {observed!r}")


def verify_matrix(driver, stream, cases, version, digest, driver_sha):
    def write(value):
        stream.write(json.dumps(value, sort_keys=True) + "\n")
        stream.flush()

    initial = driver.binary_identity()
    check_identity(initial, version, digest)
    write({"event": "begin", "build": initial, "fixture_driver_sha256": driver_sha, "cases": cases})
    exercised = set()
    for case in cases:
        recipe, expected = CASES[case]
        check_identity(driver.binary_identity(), version, digest)
        with driver.open_fixture(case) as fixture:
            evidence = recipe(fixture)
            if set(evidence) != expected or exercised.intersection(evidence):
                raise RuntimeError(f"Unexpected or duplicate operation evidence for {case}: {set(evidence)!r}")
        # The context manager closes only its bound disposable project. The
        # driver then checks the native project and its owned helper windows.
        driver.verify_fixture_cleanup(case)
        check_identity(driver.binary_identity(), version, digest)
        for operation, record in sorted(evidence.items()):
            if not record or record.get("operation", operation) != operation:
                raise RuntimeError(f"Operation identity or evidence missing for {operation}")
            write({"event": "operation", "case": case, "operation": operation, "result": "verified",
                   "evidence": record})
        exercised.update(evidence)
    final = driver.binary_identity()
    check_identity(final, version, digest)
    write({"event": "completed", "build": final, "operations": sorted(exercised)})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--driver", type=Path, required=True, help="Trusted local Python fixture driver")
    parser.add_argument("--version", required=True, help="Expected installed Conductor version")
    parser.add_argument("--sha256", required=True, help="Expected running executable SHA-256")
    parser.add_argument("--receipt", type=Path, required=True, help="New JSON Lines evidence file")
    parser.add_argument("--case", choices=CASES, action="append", dest="cases",
                        help="Run selected fixtures. Default runs the complete matrix.")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{64}", args.sha256):
        parser.error("--sha256 must be 64 lowercase hexadecimal digits")
    cases = args.cases or list(CASES)
    if len(set(cases)) != len(cases):
        parser.error("each case can be requested once")
    driver_path = args.driver.resolve(strict=True)
    driver_sha = sha256(driver_path.read_bytes()).hexdigest()
    driver = runpy.run_path(str(driver_path))["make_driver"]()
    with args.receipt.open("x", encoding="utf-8") as stream:
        verify_matrix(driver, stream, cases, args.version, args.sha256, driver_sha)


if __name__ == "__main__":
    main()
