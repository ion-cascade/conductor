"""Qualify one Compressor sidechain against aligned control and keyed bounces."""

from hashlib import sha256
import math
import struct
from uuid import uuid4


OPERATION = "plugins.set_sidechain_verified"
KEY = "Bus 2 ← Audio 1"
RATE = 44100
BOUNDS = {"start": "1.1.1.1", "end": "3.1.1.1"}


def require(condition, message, evidence):
    if not condition:
        raise RuntimeError(f"{message}: {evidence!r}")


def measurements(wav):
    require(wav[:4] == b"RIFF" and wav[8:12] == b"WAVE", "Expected a WAVE bounce", wav[:12])
    chunks = {}
    offset = 12
    while offset + 8 <= len(wav):
        kind, size = struct.unpack_from("<4sI", wav, offset)
        offset += 8
        require(offset + size <= len(wav), "Truncated WAVE chunk", (kind, size))
        if kind in (b"fmt ", b"data"):
            require(kind not in chunks, "Duplicate WAVE chunk", kind)
            chunks[kind] = wav[offset:offset + size]
        offset += size + (size & 1)
    format_tag, channels, rate, _, block, depth = struct.unpack_from("<HHIIHH", chunks[b"fmt "])
    require(format_tag in (1, 65534) and (channels, rate, block, depth) == (2, RATE, 6, 24),
            "Unexpected stereo PCM format", (format_tag, channels, rate, block, depth))
    pcm = chunks[b"data"]
    require(len(pcm) == RATE * block * 4, "Incorrect exact-range bounce length", len(pcm))
    samples = [int.from_bytes(pcm[i:i + 3], "little", signed=True) for i in range(0, len(pcm), block)]
    coefficient = 1 - math.exp(-math.tau * 520 / RATE)
    first = second = third = fourth = 0.0
    filtered = []
    for sample in samples:
        first += coefficient * (sample - first)
        second += coefficient * (first - second)
        third += coefficient * (second - third)
        fourth += coefficient * (third - fourth)
        filtered.append(fourth)

    block_size = RATE // 4
    piano = [math.sqrt(sum(v * v for v in filtered[i:i + block_size]) / block_size)
             for i in range(block_size, 6 * block_size, block_size)]

    def key_amplitude(start):
        values = samples[round(start * RATE):round((start + 1) * RATE):2]
        theta = 2 * math.tau * 2351 / RATE
        return 2 * abs(sum(v * complex(math.cos(i * theta), math.sin(i * theta))
                           for i, v in enumerate(values))) / len(values)

    return {"piano": piano, "key": [key_amplitude(.5), key_amplitude(1.5)],
            "frames": len(samples), "pcm_sha256": sha256(pcm).hexdigest()}


def compare(control, keyed):
    base = control["piano"]
    require(max(base) > 30_000 and min(control["key"] + keyed["key"]) > 100_000,
            "Control has insufficient energy to measure keying", (control, keyed))
    ratios = [after / before for before, after in zip(base, keyed["piano"]) if before > .4 * max(base)]
    require(len(ratios) >= 3 and sorted(ratios)[len(ratios) // 2] < .82,
            "The keyed bounce did not sufficiently attenuate the piano", ratios)
    key_ratios = [after / before for before, after in zip(control["key"], keyed["key"])]
    require(all(abs(ratio - 1) < .1 for ratio in key_ratios), "The adjacent key signal changed", key_ratios)
    return {"piano_ratios": ratios, "key_ratios": key_ratios}


def qualify_sidechain(fixture):
    client = fixture.client

    def binding(current):
        fixture.require_project(current)
        report = current.verified("plugins", "get_inventory", {"track": 0})
        occupied = [row for row in report["plugins"] if row["occupied"]]
        compressors = [row for row in occupied if row["name"] == "Compressor" and row.get("bypassed") is False]
        require(len(compressors) == 1, "Expected one active Compressor", occupied)
        target = compressors[0].get("plugin_insert_ref")
        require(isinstance(target, str) and target.startswith("ins_"), "Compressor reference unavailable", report)
        signature = [(row["insert"], row["name"], row.get("bypassed")) for row in occupied]
        return target, signature

    def observe(current, ref, wanted, tag):
        reading = current.verified("plugins", "get_sidechain_verified", {"target_ref": ref})
        require(reading["source"] == wanted and reading.get("editor_restored") is True
                and reading.get("write_attempted") is False, "Independent sidechain read differs", reading)
        native = fixture.native_source(tag)
        require(native == wanted, "Native sidechain popup differs", native)
        return reading

    def change(current, ref, old, new, refusal=None):
        if refusal is not None:
            return current.call("plugins", "set_sidechain_verified",
                                {"target_ref": ref, "expected_current": old, "source": new}, refusal=refusal)
        result = current.verified("plugins", "set_sidechain_verified",
                                  {"target_ref": ref, "expected_current": old, "source": new})
        require(result["source"] == new and result.get("write_attempted") is (new != old)
                and result.get("editor_restored") is True, "Change failed to bind the native editor", result)
        return result

    ref, peers = binding(client)
    before = observe(client, ref, KEY, "before")
    negative = [
        change(client, ref, "Internal", "Internal", "stale_snapshot"),
        change(client, f"ins_{uuid4()}", KEY, "Internal", "stale_target_reference"),
        change(client, ref, KEY, "Bus 2 ← Unrelated track", "readback_unavailable"),
    ]
    unchanged = observe(client, ref, KEY, "after-refusals")
    control_write = change(client, ref, KEY, "Internal")
    control_read = observe(client, ref, "Internal", "control")
    client.verified("project", "save")
    control = measurements(fixture.bounce(client, "control", BOUNDS))
    fixture.show_mixer(client)

    ref, current_peers = binding(client)
    require(current_peers == peers, "Insert inventory changed before the keyed bounce", current_peers)
    written = change(client, ref, "Internal", KEY)
    keyed_read = observe(client, ref, KEY, "keyed")
    client.verified("project", "save")
    keyed = measurements(fixture.bounce(client, "keyed", BOUNDS))
    comparisons = compare(control, keyed)

    client = fixture.reopen()
    fresh, reopened_peers = binding(client)
    require(reopened_peers == peers and fresh != ref, "Reopened insert differs", reopened_peers)
    negative.append(change(client, ref, KEY, "Internal", "stale_target_reference"))
    reopened = observe(client, fresh, KEY, "reopened")
    return {"operation": OPERATION, "control_write": control_write, "write": written, "refusals": negative,
            "readback": [before, unchanged, control_read, keyed_read, reopened],
            "control": control, "keyed": keyed, "comparison": comparisons}
