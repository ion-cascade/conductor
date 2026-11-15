"""Qualify the selected Pattern step without changing its velocity or adjacent steps."""

OPERATION = "project.set_pattern_step_enabled"
KICK = "01: Kick 1 - C1"


def require(condition, message, payload):
    if not condition:
        raise RuntimeError(f"{message}: {payload!r}")


def qualify_pattern_step(fixture):
    client = fixture.client
    native_before = fixture.native_step("before", "read")
    require(native_before[:2] == (1, 64) and len(native_before) == 6,
            "Pattern fixture did not expose the expected kick step", native_before)
    before = client.verified("project", "get_pattern_step")
    address = before["address"]
    require(address["row"] == KICK and address["step"] == 2
            and before["enabled"] is True and before["velocity"] == 64, "Incorrect Pattern step", before)

    def request(current, wanted, expected, *, target=address, refusal=None):
        params = {"address": target, "expected_enabled": expected, "enabled": wanted}
        if refusal is not None:
            return current.call("project", "set_pattern_step_enabled", params, refusal=refusal)
        answer = current.verified("project", "set_pattern_step_enabled", params)
        require(answer["enabled"] is wanted and answer["velocity"] == 64
                and answer["address"] == address and answer["write_attempted"] is (wanted != expected),
                "Pattern response did not match the selected step", answer)
        return answer

    wrong_step = request(client, False, True, target={**address, "step": 3}, refusal="stale_snapshot")
    stale = request(client, False, False, refusal="stale_snapshot")
    request(client, True, True)
    require(fixture.native_step("after-refusal", "read") == native_before,
            "A refused or no-op write changed the grid", native_before)
    mutation = request(client, False, True)
    native_after = fixture.native_step("after", "read")
    require(native_after == (0, *native_before[1:]), "Native neighboring steps or velocity drifted", native_after)
    client.verified("project", "save")

    client = fixture.reopen()
    native_reopened = fixture.native_step("reopened", "peek")
    require(native_reopened == (0, 64), "Native Pattern setting did not persist", native_reopened)
    reopened = client.verified("project", "get_pattern_step")
    require(reopened["address"] == address and reopened["enabled"] is False
            and reopened["visible_grid"] == mutation["visible_grid"], "Reopened grid differs", reopened)
    restored = request(client, True, False)
    require(fixture.native_step("restored", "read") == native_before
            and restored["visible_grid"] == before["visible_grid"], "Pattern grid was not restored", restored)
    client.verified("project", "save")
    return {"operation": OPERATION, "write": mutation, "restored": restored, "refusals": [wrong_step, stale],
            "native": {"before": native_before, "after": native_after, "reopened": native_reopened},
            "reopened_grid": reopened["visible_grid"]}
