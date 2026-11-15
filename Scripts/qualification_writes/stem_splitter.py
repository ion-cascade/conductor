"""Verify the native stem files and arrangement after a single selected-region split."""

from collections import Counter
from hashlib import sha256
from uuid import uuid4


OPERATION = "tracks.split_selected_audio"
LABELS = ("Vocals", "Drums", "Bass", "Guitar", "Piano", "Other")


def require(condition, message, evidence):
    if not condition:
        raise RuntimeError(f"{message}: {evidence!r}")


def signature(rows):
    return Counter((row["name"], row["kind"], row.get("startPosition"), row.get("endPosition")) for row in rows)


def qualify_stem_splitter(fixture):
    client = fixture.client
    fixture.require_project(client)
    initial = client.call("project", "get_regions")["regions"]
    selected = [row for row in initial if row.get("isSelected") is True]
    require(len(selected) == 1 and selected[0].get("kind") == "audio",
            "Fixture must expose one selected audio region", selected)
    source = selected[0]
    name = source["name"]
    start, end = source["startPosition"], source["endPosition"]
    binding = fixture.track_binding(client, source["trackIndex"])
    directory = fixture.project_path + "/Media/Audio Files/"
    inputs = fixture.list_audio()
    original_files = [path for path in inputs if path.rsplit("/", 1)[-1].rsplit(".", 1)[0] == name]
    require(len(original_files) == 1 and original_files[0].startswith(directory),
            "Source file could not be bound to the selected region", original_files)
    original = original_files[0]
    original_hash = sha256(fixture.read_file(original)).hexdigest()
    audio_shape = fixture.audio_shape(original)

    request = {**binding, "region_name": name, "start": start, "end": end, "confirmed": True}
    refuses = [
        client.call("tracks", "split_selected_audio", {**request, "region_name": name + " Wrong"},
                    refusal="readback_unavailable"),
        client.call("tracks", "split_selected_audio", {**request, "target_ref": f"trk_{uuid4()}"},
                    refusal="stale_target_reference"),
    ]
    unchanged = client.call("project", "get_regions")["regions"]
    require(signature(initial) == signature(unchanged) and set(fixture.list_audio()) == set(inputs)
            and sha256(fixture.read_file(original)).hexdigest() == original_hash,
            "A refused split changed media or region placement", unchanged)
    result = client.verified("tracks", "split_selected_audio", request)
    stems = result["stems"]
    require(result.get("write_attempted") is True and result.get("source_muted") is True
            and [row["stem"] for row in stems] == [label.lower() for label in LABELS]
            and len({row["track"] for row in stems}) == len(LABELS), "Missing split results", result)

    expected = [directory + f"{name}_{label}.aif" for label in LABELS]
    require([row["path"] for row in stems] == expected, "Split artifacts escaped the owned media directory", stems)

    def observe(current):
        fixture.require_project(current)
        readback = current.call("project", "scan_regions")
        require(readback.get("restoration") == "restored", "Follow-up inventory failed to restore Arrange", readback)
        observed = signature(row["region"] for row in readback["regions"])
        wanted = signature(initial)
        del wanted[(name, "audio", start, end)]
        wanted += Counter([(name + ", muted", "audio", start, end)]
                          + [(f"{name} ({label})", "audio", start, end) for label in LABELS])
        require(observed == wanted, "Split placement, source mute or neighboring regions differ", observed)
        require(set(fixture.list_audio()) == set(inputs + expected), "Wrong generated audio files", expected)
        require(sha256(fixture.read_file(original)).hexdigest() == original_hash, "Source audio was rewritten", original)
        hashes = {}
        for path in expected:
            raw = fixture.read_file(path)
            require(raw[:4] == b"FORM" and raw[8:12] in (b"AIFF", b"AIFC")
                    and fixture.audio_shape(path) == audio_shape, "Incorrect native output format", path)
            hashes[path.rsplit("/", 1)[-1]] = {"sha256": sha256(raw).hexdigest(), "bytes": len(raw)}
        return {"media": hashes, "inventory": readback["regions"]}

    read = observe(client)
    client.verified("project", "save")
    client = fixture.reopen()
    refuses.append(client.call("tracks", "split_selected_audio", request, refusal="stale_target_reference"))
    reopened = observe(client)
    require(read["media"] == reopened["media"], "Generated assets drifted after reopen", reopened["media"])
    return {"operation": OPERATION, "write": result, "refusals": refuses, "source_sha256": original_hash,
            "audio_shape": audio_shape, "readback": read, "reopened": reopened}
