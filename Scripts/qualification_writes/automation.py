"""Qualification recipes for creating and editing native automation events."""

from dataclasses import dataclass
from uuid import uuid4


START, END = "1.1.1.1", "2.1.1.1"


@dataclass(frozen=True)
class Lane:
    name: str
    create: str
    set_point: str
    seeded_positions: tuple[str, ...]
    seeded_value: int

    def create_args(self):
        if self.name == "pan":
            return {"initial_position": START, "position": END}
        return {"start": START, "end": END}


LANES = {
    "volume": Lane("volume", "create_volume_automation_at_region_borders", "set_volume_automation_point",
                   ("0.4.4.240", START, "1.4.4.240", END), 90),
    "pan": Lane("pan", "create_pan_automation_point", "set_pan_automation_point", (START, END), 64),
}


def require(condition, message, payload):
    if not condition:
        raise RuntimeError(f"{message}: {payload!r}")


def points(rows):
    result = [(row["position"], row["value"]) for row in rows]
    require(len({position for position, _ in result}) == len(result)
            and all(type(value) is int for _, value in result), "Invalid native event rows", rows)
    return result


def qualify_automation(fixture, lane_name):
    """The fixture stages one owned lane and acquires native event-list evidence."""
    lane = LANES[lane_name]
    client = fixture.client
    binding = fixture.prepare_lane(lane_name)
    baseline = fixture.native_lanes("baseline", lane_name)
    require(points(baseline["target"]) == [], "Creation fixture needs an empty target lane", baseline)
    peer_lanes = baseline["peers"]

    def observe(tag, expected):
        result = fixture.native_lanes(tag, lane_name)
        require(points(result["target"]) == expected and result["peers"] == peer_lanes,
                "Incorrect native events or changed peer lanes", result)
        return result

    create = {**binding, **lane.create_args()}
    create_refusal = client.call("tracks", lane.create, {**create, "target_ref": f"trk_{uuid4()}"},
                                 refusal="stale_target_reference")
    observed_after_create_refusal = observe("create-refusal", [])
    binding = fixture.prepare_creation(lane_name)
    create = {**binding, **lane.create_args()}
    created = client.verified("tracks", lane.create, create)
    require(created.get("write_attempted") is True, "Creation did not reach the write", created)
    seeded = [(pos, lane.seeded_value) for pos in lane.seeded_positions]
    observed_created = observe("created", seeded)
    client.verified("project", "save")

    retired = binding
    client, binding = fixture.reopen(lane_name)
    require(binding["target_ref"] != retired["target_ref"], "Reopen retained a stale track handle", binding)
    stale_create = client.call("tracks", lane.create, {**binding, **lane.create_args(),
                                                       "target_ref": retired["target_ref"]},
                               refusal="stale_target_reference")
    observed_created_reopened = observe("created-reopened", seeded)

    def edit_one_point():
        reading = client.verified("tracks", f"get_{lane_name}_automation", binding)
        require(points(reading["points"]) == seeded, "The event list moved before editing", reading)
        selected = reading["selected_positions"]
        affected = selected if START in selected else [START]
        require(1 <= len(affected) <= 2 and START in affected
                and set(affected).issubset(lane.seeded_positions), "The selected cohort is unsupported", selected)
        desired = lane.seeded_value - 10 if lane_name == "volume" else lane.seeded_value + 10
        args = {**binding, "position": START, "expected_current": lane.seeded_value, "value": desired}
        if len(affected) == 2:
            args["linked_position"] = next(pos for pos in affected if pos != START)
        refused = client.call("tracks", lane.set_point, {**args, "expected_current": desired},
                              refusal="stale_snapshot")
        reading = client.verified("tracks", f"get_{lane_name}_automation", binding)
        require(points(reading["points"]) == seeded, "Stale expectation moved an automation point", reading)
        updated = client.verified("tracks", lane.set_point, args)
        require(updated.get("write_attempted") is True and updated.get("observed") == desired
                and sorted(updated.get("affected_positions", [])) == sorted(affected),
                "The edited cohort differs from the requested cohort", updated)
        return (args, refused, updated,
                [(pos, desired if pos in affected else value) for pos, value in seeded])

    args, stale_edit, edited, edit_expected = fixture.with_event_list("edit", lane_name, edit_one_point)
    observed_edited = observe("edited", edit_expected)
    client.verified("project", "save")

    old = binding
    client, binding = fixture.reopen(lane_name)
    stale_edit_ref = client.call("tracks", lane.set_point, {**args, "project_ref": binding["project_ref"],
                                                           "target_ref": old["target_ref"]},
                                 refusal="stale_target_reference")
    observed_edited_reopened = observe("edited-reopened", edit_expected)
    return {
        f"tracks.{lane.create}": {"write": created, "refusals": [create_refusal, stale_create],
                                  "native": [baseline, observed_after_create_refusal,
                                             observed_created, observed_created_reopened]},
        f"tracks.{lane.set_point}": {"write": edited, "refusals": [stale_edit, stale_edit_ref],
                                     "native": [observed_created_reopened, observed_edited,
                                                observed_edited_reopened]},
    }
