import copy
import unittest
from unittest.mock import patch

from Scripts.qualification_writes import mixer


class MixerQualificationTests(unittest.TestCase):
    def baseline(self):
        return {"strips": [
            {"name": name, "mixer_strip_ref": f"mix_{i}", "isMuted": False,
             **({"isSoloed": False} if i < 3 else {"unavailable_fields": ["isSoloed"]})}
            for i, name in enumerate(mixer.FIXTURE_STRIPS)
        ]}

    def test_duplicate_references_are_rejected_even_for_same_name_strips(self):
        sample = self.baseline()
        sample["strips"][2]["mixer_strip_ref"] = sample["strips"][1]["mixer_strip_ref"]
        with self.assertRaisesRegex(RuntimeError, "Unbound or duplicate strip"):
            mixer.switches(sample)

    def test_integer_is_not_an_observed_boolean(self):
        sample = self.baseline()
        sample["strips"][2]["isMuted"] = 0
        with self.assertRaisesRegex(RuntimeError, "Native switch value unavailable"):
            mixer.switches(sample)

    def test_wrong_twin_cannot_qualify_even_with_verified_write_reply(self):
        sample = self.baseline()
        changed = copy.deepcopy(sample)
        changed["strips"][1]["isMuted"] = True

        class Client:
            def call(self, tool, command, params, refusal):
                if refusal != "stale_target_reference":
                    raise RuntimeError(refusal)
                return {"state": "C", "write_attempted": False}

            def verified(self, tool, command, params):
                return {"state": "A", "target_ref": params["target_ref"], "write_attempted": True}

        with patch.object(mixer, "mixer_snapshot", side_effect=[(1, sample), (2, sample), (3, changed)]):
            with self.assertRaisesRegex(RuntimeError, "Wrong switch"):
                mixer.qualify_mixer_switch(Client(), "mixer.set_mute", "/fixture.logicx", "prj_fixture")
