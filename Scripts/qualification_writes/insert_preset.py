"""Qualify the bounded Compressor preset write in a disposable project."""

from uuid import uuid4


OPERATION = "plugins.set_preset_verified"
PRESET = "02 Keyboards/Piano"


def require(condition, message, payload):
    if not condition:
        raise RuntimeError(f"{message}: {payload!r}")


def slots(client, fixture):
    fixture.require_project(client)
    inventory = client.call("plugins", "get_inventory", {"track": 0})
    occupied = [row for row in inventory["plugins"] if row["occupied"]]
    matches = [row for row in occupied if row["name"] == "Compressor"]
    require(len(matches) == 1, "Fixture needs exactly one occupied Compressor", occupied)
    target = matches[0]
    ref, project = target.get("plugin_insert_ref"), inventory.get("project_ref")
    require(isinstance(ref, str) and ref.startswith("ins_") and isinstance(project, str)
            and project.startswith("prj_"), "Compressor and project references were not acquired", inventory)
    shape = tuple((row["insert"], row["name"], row.get("bypassed")) for row in occupied)
    return {"target_ref": ref, "project_ref": project}, target["insert"], shape


def qualify_insert_preset(fixture):
    client = fixture.client
    binding, index, peers = slots(client, fixture)

    def observe(label, expected):
        readback = fixture.native_preset(label, index)
        require(readback["insert"] == index and readback["preset"] == expected,
                "Independent Compressor preset observation differed", readback)
        return readback

    original = observe("before", "Custom")
    stale = {**binding, "expected_current": "Piano", "path": PRESET}
    write = {**binding, "expected_current": "Custom", "path": PRESET}
    refused = [
        client.call("plugins", "set_preset_verified", stale, refusal="stale_snapshot"),
        client.call("plugins", "set_preset_verified", {**write, "target_ref": f"ins_{uuid4()}"},
                    refusal="stale_target_reference"),
    ]
    after_refusal = observe("after-refusal", "Custom")
    response = client.call("plugins", "set_preset_verified", write)
    require(response.get("state") in ("A", "B") and response.get("write_attempted") is True,
            "Preset change never reached the write", response)
    immediate = observe("immediate", "Piano")
    require(slots(client, fixture)[1:] == (index, peers), "Occupied insert inventory drifted", peers)
    client.verified("project", "save")

    client = fixture.reopen()
    fresh, reopened_index, reopened_peers = slots(client, fixture)
    require(fresh["target_ref"] != binding["target_ref"] and reopened_index == index and reopened_peers == peers,
            "The re-opened insert inventory does not match", (fresh, reopened_index, reopened_peers))
    refused.append(client.call("plugins", "set_preset_verified",
                               {**write, "project_ref": fresh["project_ref"]},
                               refusal="stale_target_reference"))
    reopened = observe("reopened", "Piano")
    return {
        "operation": OPERATION, "write": response, "refusals": refused, "occupied_slots": peers,
        "native": {"before": original, "after_refusal": after_refusal,
                   "immediate": immediate, "reopened": reopened},
    }
