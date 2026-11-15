"""Operation-bound checks against the gain and fade fixture used for the 1.8 release."""

from array import array
from hashlib import sha256
from io import BytesIO
import math
import sys
import wave


TARGET = (1, "Stem 731_1")
NEIGHBOR = (2, "Stem 967")
BOUNDS = {"start": "1.1.1.1", "end": "4.1.1.1"}
RATE = 48000
FRAMES = 10 * RATE
TARGET_TONE = 1900
NEIGHBOR_TONE = 1490


def require(condition, message, payload):
    if not condition:
        raise RuntimeError(f"{message}: {payload!r}")


def region_ref(client, identity=TARGET):
    result = client.call("project", "scan_regions")
    require(result["restoration"] == "restored", "Arrange presentation changed during scan", result)
    matches = [row for row in result["regions"]
               if (row["region"]["trackIndex"], row["region"]["name"]) == identity]
    require(len(matches) == 1, "Region identity is ambiguous", matches)
    reference = matches[0].get("target_ref")
    require(isinstance(reference, str) and reference.startswith("reg_"), "Region reference unavailable", matches)
    return reference


def regions(client):
    records = client.call("project", "get_regions")["regions"]
    return [{key: value for key, value in row.items() if key != "isSelected"} for row in records]


def write(client, operation, target, before, desired, *, edge=None, refusal=None):
    name = operation.split(".")[1]
    field = "gain_db" if edge is None else "time_ms"
    params = {"target_ref": target, f"expected_{field}": before, field: desired}
    if edge is not None:
        params["edge"] = edge
    if refusal is not None:
        return client.call("project", name, params, refusal=refusal)
    result = client.verified("project", name, params)
    require(result.get("operation") == operation and result.get("target_ref") == target
            and result.get(f"observed_{field}") == desired and result.get("write_attempted") is True
            and result.get("reference_reread_required") is True
            and result.get("neighboring_regions_verified") is True,
            "Write did not verify the requested region setting", result)
    return result


def bounce(client, fixture, tag):
    out = fixture.make_output_directory(tag)
    receipt = client.call("project", "export_run", {
        "confirmed": True, "projects": [fixture.project_path], "output_root": out,
        "artifacts": ["bounce"],
        "bounce_settings": {
            "format": "wav", "sample_rate": RATE, "bit_depth": 16,
            "include_audio_tail": False, "range": BOUNDS,
        },
    })
    require(receipt["artifacts_verified"] == 1, "Expected one verified bounce", receipt)
    project, = receipt["projects"]
    artifact, = project["artifacts"]
    require(artifact.get("observed_bounce_range") == BOUNDS and artifact["path"].startswith(out + "/"),
            "Wrong bounce bounds or destination", artifact)
    with wave.open(BytesIO(fixture.read_file(artifact["path"]))) as wav:
        shape = (wav.getnchannels(), wav.getframerate(), wav.getsampwidth(), wav.getnframes())
        require(shape == (2, RATE, 2, FRAMES), "Unexpected stereo PCM format", shape)
        pcm = wav.readframes(FRAMES)
    require(len(pcm) == FRAMES * 4, "Truncated bounce", len(pcm))
    samples = array("h")
    samples.frombytes(pcm)
    if sys.byteorder != "little":
        samples.byteswap()
    return samples[::2], sha256(pcm).hexdigest()


def amplitude(samples, frequency, second):
    count = 1920
    first = round(second * RATE) - count // 2
    window = samples[first:first + count]
    require(len(window) == count, "Measurement window runs outside bounce", second)
    phase = math.tau * frequency / RATE
    return abs(sum(sample * (1 - math.cos(math.tau * i / count))
                   * complex(math.cos(phase * i), math.sin(phase * i))
                   for i, sample in enumerate(window))) * 2 / count


def ratio(control, edited, tone, second):
    reference = amplitude(control, tone, second)
    require(reference > 200, "Control tone missing from measurement window", (tone, second, reference))
    return amplitude(edited, tone, second) / reference


def qualify_region_parameters(fixture):
    """Run both operations in one project with a shared control and gain-only bounce.

    The fixture owns the native Inspector probe, saved-project lifecycle, source files
    and render destinations. Its observations are acquired separately from MCP write replies.
    """
    gain, fade = "project.set_region_gain", "project.set_region_fade"
    client = fixture.client
    observations = {}

    def observe(tag, **expected):
        observations[tag] = fixture.observe(tag, **expected)

    observe("initial", gain=0, fades=(0, 0), action="expand")
    original_regions = regions(client)
    original_sources = fixture.source_hashes()
    require(len(original_regions) == 4 and len(original_sources) == 2,
            "Unexpected audio-region qualification fixture", original_regions)

    def unchanged(current):
        observed_regions = regions(current)
        observed_sources = fixture.source_hashes()
        require(observed_regions == original_regions, "Region boundaries or peers moved", observed_regions)
        require(observed_sources == original_sources, "Bundled source audio changed", observed_sources)

    client.verified("project", "save")
    control, control_sha = bounce(client, fixture, "control")
    observe("control", gain=0, fades=(0, 0), action="expand")

    negatives = {}
    for operation, desired, edge in ((gain, -6, None), (fade, 500, "in")):
        negatives[operation] = [
            write(client, operation, region_ref(client), 100, desired, edge=edge,
                  refusal="stale_target_reference"),
            write(client, operation, region_ref(client, NEIGHBOR), 0, desired, edge=edge,
                  refusal="unsupported_state"),
        ]
    fixture.multiselect()
    for operation, desired, edge in ((gain, -6, None), (fade, 500, "in")):
        negatives[operation].append(write(client, operation, region_ref(client), 0, desired, edge=edge,
                                          refusal="unsupported_state"))
    observe("single", gain=0, fades=(0, 0), action="single")
    unchanged(client)

    ref = region_ref(client)
    gain_write = write(client, gain, ref, 0, -6)
    observe("gain-immediate", gain=-6, fades=(0, 0))
    negatives[gain].append(write(client, gain, ref, -6, 0, refusal="stale_target_reference"))
    unchanged(client)
    client.verified("project", "save")
    gained, gain_sha = bounce(client, fixture, "gain")
    observe("gain-bounce", gain=-6, fades=(0, 0), action="expand")
    gain_windows = (.1, .4, 1, 3, 6, 9.6)
    gain_db = [20 * math.log10(ratio(control, gained, TARGET_TONE, t)) for t in gain_windows]
    gain_peer_db = [20 * math.log10(ratio(control, gained, NEIGHBOR_TONE, t)) for t in gain_windows]
    require(max(abs(delta + 6) for delta in gain_db) < .2 and max(map(abs, gain_peer_db)) < .2,
            "Gain or adjacent tone failed the bounce comparison", (gain_db, gain_peer_db))

    ref = region_ref(client)
    fade_in = write(client, fade, ref, 0, 500, edge="in")
    observe("fade-in-immediate", gain=-6, fades=(500, 0))
    negatives[fade].append(write(client, fade, ref, 500, 0, edge="in", refusal="stale_target_reference"))
    fade_out = write(client, fade, region_ref(client), 0, 1000, edge="out")
    observe("fade-out-immediate", gain=-6, fades=(500, 1000))
    unchanged(client)

    retired = region_ref(client)
    client.verified("project", "save")
    client = fixture.reopen()
    observe("reopened", gain=-6, fades=(500, 1000), action="expand")
    negatives[gain].append(write(client, gain, retired, -6, 0, refusal="stale_target_reference"))
    negatives[fade].append(write(client, fade, retired, 1000, 0, edge="out", refusal="stale_target_reference"))
    observe("neighbor", gain=0, fades=(0, 0), action="neighbor", stem=NEIGHBOR[1])
    observe("reselect", gain=-6, fades=(500, 1000), action="expand")
    faded, fade_sha = bounce(client, fixture, "reopened")
    unchanged(client)
    fade_windows = (.05, .125, .25, .375, .525, 2, 8, 9.05, 9.25, 9.5, 9.75, 9.95)
    measured = [ratio(gained, faded, TARGET_TONE, t) for t in fade_windows]
    expected = [min(1, t / .5, (10 - t) / 1) for t in fade_windows]
    fade_peer_db = [20 * math.log10(ratio(gained, faded, NEIGHBOR_TONE, t)) for t in fade_windows]
    require(max(abs(a - b) for a, b in zip(measured, expected)) < .08 and max(map(abs, fade_peer_db)) < .2,
            "Fade envelope or adjacent tone failed the bounce comparison", (measured, expected, fade_peer_db))
    preservation = {"regions": original_regions, "source_sha256": original_sources}
    return {
        gain: {"writes": [gain_write], "refusals": negatives[gain], "control_pcm_sha256": control_sha,
               "edited_pcm_sha256": gain_sha, "target_delta_db": gain_db, "neighbor_delta_db": gain_peer_db,
               "preservation": preservation,
               "native": {tag: observations[tag] for tag in ("initial", "gain-immediate", "reopened", "neighbor")}},
        fade: {"writes": [fade_in, fade_out], "refusals": negatives[fade], "control_pcm_sha256": gain_sha,
               "edited_pcm_sha256": fade_sha, "fade_ratios": list(zip(fade_windows, measured, expected)),
               "neighbor_delta_db": fade_peer_db, "preservation": preservation,
               "native": {tag: observations[tag] for tag in
                          ("gain-bounce", "fade-in-immediate", "fade-out-immediate", "reopened", "neighbor")}},
    }
