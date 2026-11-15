"""Verify bypass and restoration for one occupied insert beside an identical peer."""

from uuid import uuid4


OPERATION = "plugins.set_bypass_verified"
BASELINE = ((0, "Channel EQ", False), (1, "Compressor", False),
            (2, "ChromaVerb", False), (3, "Compressor", False))
TARGET = 3


def require(condition, message, payload):
    if not condition:
        raise RuntimeError(f"{message}: {payload!r}")


def inventory(client, fixture, expected):
    fixture.require_project(client)
    result = client.call("plugins", "get_inventory", {"track": 0})
    occupied = [row for row in result["plugins"] if row["occupied"]]
    slots = {row["insert"]: row for row in occupied}
    require(len(slots) == len(occupied), "Duplicate occupied insert ordinals", occupied)
    states = tuple((index, row["name"], row.get("bypassed")) for index, row in sorted(slots.items()))
    require(states == expected and all(type(row[2]) is bool for row in states),
            "Insert inventory differs from expected physical slots", states)
    refs = {index: row.get("plugin_insert_ref") for index, row in slots.items()}
    require(all(isinstance(ref, str) and ref for ref in refs.values()) and len(set(refs.values())) == len(slots),
            "An occupied slot is unbound or ambiguous", refs)
    project_ref = result.get("project_ref")
    require(isinstance(project_ref, str) and project_ref.startswith("prj_"),
            "Insert inventory has no project reference", result)
    return project_ref, refs


def qualify_insert_bypass(fixture):
    client = fixture.client

    def observe(label, expected):
        rows = fixture.native_slots(label)
        require(tuple(tuple(row) for row in rows) == expected, "Native insert states disagree", rows)
        return rows

    def request(client, current_project, ref, previous, desired, *, refusal=None):
        arguments = {"project_ref": current_project, "target_ref": ref,
                     "expected_current": previous, "bypassed": desired}
        if refusal:
            return client.call("plugins", "set_bypass_verified", arguments, refusal=refusal)
        result = client.verified("plugins", "set_bypass_verified", arguments)
        require(result.get("insert") == TARGET and result.get("bypassed") is desired
                and result.get("write_attempted") is True and result.get("changed") is True,
                "Bypass reply does not describe the requested physical insert", result)
        return result

    project_ref, refs = inventory(client, fixture, BASELINE)
    original = observe("baseline", BASELINE)
    refused = [
        request(client, project_ref, refs[TARGET], True, False, refusal="stale_snapshot"),
        request(client, project_ref, f"ins_{uuid4()}", False, True, refusal="stale_target_reference"),
    ]
    after_refusal = observe("after-refusal", BASELINE)
    changed = BASELINE[:-1] + ((TARGET, "Compressor", True),)
    written = request(client, project_ref, refs[TARGET], False, True)
    immediate = observe("immediate", changed)
    inventory(client, fixture, changed)
    client.verified("project", "save")

    client = fixture.reopen()
    current_project, fresh = inventory(client, fixture, changed)
    refused.append(request(client, current_project, refs[TARGET], True, False, refusal="stale_target_reference"))
    reopened = observe("reopened", changed)
    restored = request(client, current_project, fresh[TARGET], True, False)
    after_restore = observe("restored", BASELINE)
    client.verified("project", "save")
    return {
        "operation": OPERATION, "refusals": refused, "write": written, "restore": restored,
        "native": {"before": original, "after_refusal": after_refusal, "immediate": immediate,
                   "reopened": reopened, "restored": after_restore},
    }
