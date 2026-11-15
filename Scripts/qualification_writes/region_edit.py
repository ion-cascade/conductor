"""Qualify exact offscreen audio-region movement and trimming."""

from collections import Counter


OPERATION = "project.edit_region"
REGION_NAME = "Conductor Range Witness"
ORIGINAL = ("54.1.1.1", "56.1.1.1")
MOVED = ("55.1.1.1", "57.1.1.1")
TRIMMED = ("55.3.1.1", "57.1.1.1")


def require(condition, message, payload):
    if not condition:
        raise RuntimeError(f"{message}: {payload!r}")


def scope(client, fixture):
    fixture.require_project(client)
    report = client.call("project", "scan_regions")
    require(report.get("restoration") == "restored", "Scan did not restore its viewport", report)
    require(all(len({page[axis] for page in report["sampled_pages"]}) > 1
                for axis in ("horizontal", "vertical")), "The offscreen fixture did not exercise both axes", report)
    fixture.require_project(client)
    return report["regions"]


def signature(region):
    return tuple(region.get(key) for key in ("trackIndex", "name", "kind", "startPosition", "endPosition"))


def fingerprint(rows):
    return Counter(signature(row["region"]) for row in rows)


def target(rows, bounds):
    matches = [row for row in rows if row["region"]["name"] == REGION_NAME
               and row["region"]["kind"] == "audio"
               and signature(row["region"])[-2:] == bounds]
    require(len(matches) == 1 and matches[0].get("target_ref", "").startswith("reg_"),
            "Could not bind exactly one target region", matches)
    return matches[0]


def arguments(row, mode, **requested):
    start, end = signature(row["region"])[-2:]
    return {"target_ref": row["target_ref"], "mode": mode,
            "expected_start": start, "expected_end": end, **requested}


def qualify_region_edit(fixture):
    client = fixture.client
    visible = client.call("project", "get_regions")["regions"]
    require(not any(row["name"] == REGION_NAME and row.get("startPosition") == ORIGINAL[0] for row in visible),
            "Target must start outside the visible Arrange inventory", visible)
    initial = scope(client, fixture)
    source = target(initial, ORIGINAL)
    identity = signature(source["region"])[:3]
    unchanged = fingerprint(initial)
    del unchanged[identity + ORIGINAL]

    def inspect(current, bounds):
        readback = scope(current, fixture)
        held = target(readback, bounds)
        require(fingerprint(readback) == unchanged + Counter([identity + bounds]),
                "Region geometry, lane identity or peer inventory disagreed", readback)
        return held

    def mutate(current, request):
        result = current.verified("project", "edit_region", request)
        require(result.get("operation") == OPERATION and result.get("write_attempted") is True
                and result.get("viewport_restored") is True and result.get("neighboring_regions_verified") is True,
                "Edit did not verify the target and peer preservation", result)
        return result

    move = arguments(source, "move", start=MOVED[0])
    negatives = [
        client.call("project", "edit_region", {**move, "target_ref": "reg_forged"},
                    refusal="stale_target_reference"),
        client.call("project", "edit_region", {**move, "expected_start": "53.1.1.1"},
                    refusal="stale_target_reference"),
    ]
    # Scan issued replacement handles. The positive write uses the fresh target.
    move = arguments(inspect(client, ORIGINAL), "move", start=MOVED[0])
    written = mutate(client, move)
    negatives.append(client.call("project", "edit_region", move, refusal="stale_target_reference"))
    moved = inspect(client, MOVED)
    trimmed_write = mutate(client, arguments(moved, "trim", start=TRIMMED[0]))
    trimmed = inspect(client, TRIMMED)
    client.verified("project", "save")

    client = fixture.reopen()
    negatives.append(client.call("project", "edit_region", move, refusal="stale_target_reference"))
    reopened = inspect(client, TRIMMED)
    return {
        "operation": OPERATION, "readback_source": "project.scan_regions", "refusals": negatives,
        "writes": [written, trimmed_write],
        "regions": {"before": source["region"], "moved": moved["region"],
                    "trimmed": trimmed["region"], "reopened": reopened["region"]},
        "peer_count": sum(unchanged.values()),
    }
