"""Live qualification for the physical Mixer strip switches on a disposable fixture."""

from datetime import datetime
import json
import time
from uuid import uuid4


COMMANDS = {
    "mixer.set_mute": "isMuted",
    "mixer.set_solo": "isSoloed",
}
FIXTURE_STRIPS = (
    "Conductor Target Bar 1", "Conductor Twins", "Conductor Twins", "Stereo Out", "Master"
)
TARGET_INDEX = 2


def require(condition, message, payload):
    if not condition:
        raise RuntimeError(f"{message}: {payload!r}")


def project_snapshot(client, project_path):
    payload = client.call("project", "inspect_session", {"domains": ["tracks"]})
    project = payload["project"]
    require(project.get("file_path") == project_path, "Lost the disposable Mixer project", project)
    return project


def mixer_snapshot(client, project_path, *, after=None):
    """Capture a fresh resource poll from the bound document."""
    project_snapshot(client, project_path)
    deadline = time.monotonic() + 20
    while True:
        client.call("system", "refresh_cache")
        reply = client.request("resources/read", {"uri": "logic://mixer"}, timeout=10)
        observed = json.loads(reply["contents"][0]["text"])
        stamp = observed.get("fetched_at")
        if (observed.get("data_source") == "ax_poll" and observed.get("ax_occluded") is False
                and stamp and observed.get("strips")):
            captured_at = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
            if after is None or captured_at > after:
                project_snapshot(client, project_path)
                return captured_at, observed
        if time.monotonic() >= deadline:
            raise RuntimeError(f"Independent Mixer read did not advance: {observed!r}")
        time.sleep(.25)


def switches(envelope):
    rows = envelope["strips"]
    require(tuple(row["name"] for row in rows) == FIXTURE_STRIPS, "Unexpected Mixer fixture", rows)
    refs = tuple(row.get("mixer_strip_ref") for row in rows)
    require(all(isinstance(ref, str) and ref.startswith("mix_") for ref in refs)
            and len(set(refs)) == len(rows), "Unbound or duplicate strip identities", refs)
    values = []
    for index, row in enumerate(rows):
        values.append({})
        for field in COMMANDS.values():
            value = row.get(field)
            if field == "isSoloed" and index >= 3:
                require(value is None and field in row.get("unavailable_fields", []),
                        "Unexpected solo availability on output strip", row)
            else:
                require(type(value) is bool, "Native switch value unavailable", row)
            values[-1][field] = value
    return refs, values


def qualify_mixer_switch(client, operation, project_path, project_ref):
    """Prove one switch changes its physical strip, then restore it by held reference."""
    field = COMMANDS[operation]
    command = operation.split(".")[1]
    stamp, before = mixer_snapshot(client, project_path)
    refs, baseline = switches(before)
    desired = not baseline[TARGET_INDEX][field]
    requested = {"project_ref": project_ref, "target_ref": refs[TARGET_INDEX], "enabled": desired}

    refused = client.call(
        "mixer", command, {**requested, "target_ref": f"mix_{uuid4()}"}, refusal="stale_target_reference"
    )
    stamp, after_refusal = mixer_snapshot(client, project_path, after=stamp)
    require(switches(after_refusal) == (refs, baseline), "Stale reference changed a switch", after_refusal)
    write = client.verified("mixer", command, requested)
    require(write.get("write_attempted") is True and write.get("target_ref") == refs[TARGET_INDEX],
            "Write did not report the held strip", write)
    stamp, changed = mixer_snapshot(client, project_path, after=stamp)
    expected = [dict(values) for values in baseline]
    expected[TARGET_INDEX][field] = desired
    require(switches(changed) == (refs, expected), "Wrong switch, peer drift or no change", changed)

    restored = client.verified("mixer", command, {**requested, "enabled": baseline[TARGET_INDEX][field]})
    require(restored.get("write_attempted") is True and restored.get("target_ref") == refs[TARGET_INDEX],
            "Restore did not report the held strip", restored)
    _, after_restore = mixer_snapshot(client, project_path, after=stamp)
    require(switches(after_restore) == (refs, baseline), "Switch state was not restored", after_restore)
    return {
        "operation": operation,
        "readback_source": "logic://mixer",
        "before": before,
        "stale_refusal": refused,
        "after_refusal": after_refusal,
        "write": write,
        "changed": changed,
        "restore": restored,
        "restored": after_restore,
    }
