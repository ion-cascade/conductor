from contextlib import contextmanager
from io import StringIO
import json
import unittest
from unittest.mock import patch

from Scripts.qualification_writes import runner


class MatrixTests(unittest.TestCase):
    def test_catalog_has_fourteen_unique_operations(self):
        operations = [operation for _, expected in runner.CASES.values() for operation in expected]
        self.assertEqual(len(operations), 14)
        self.assertEqual(len(set(operations)), 14)

    def test_live_receipt_requires_cleanup_and_the_same_binary(self):
        class Driver:
            build = {"binary": "/LogicProMCP", "sha256": "d", "version": "1.8.1"}

            def binary_identity(self):
                return dict(self.build)

            @contextmanager
            def open_fixture(self, case):
                yield case

            def verify_fixture_cleanup(self, case):
                self.build["sha256"] = "new"

        with patch.dict(runner.CASES, {"sample": (lambda _: {"write": {"verified": True}}, {"write"})}):
            stream = StringIO()
            with self.assertRaisesRegex(RuntimeError, "active bridge does not match"):
                runner.verify_matrix(Driver(), stream, ["sample"], "1.8.1", "d", "driver")
        self.assertEqual([json.loads(line)["event"] for line in stream.getvalue().splitlines()], ["begin"])

    def test_missing_operations_do_not_get_a_verified_receipt(self):
        class Driver:
            def binary_identity(self):
                return {"binary": "/LogicProMCP", "sha256": "d", "version": "1.8.1"}

            @contextmanager
            def open_fixture(self, case):
                yield case

        with patch.dict(runner.CASES, {"sample": (lambda _: {}, {"write"})}):
            stream = StringIO()
            with self.assertRaisesRegex(RuntimeError, "Unexpected or duplicate"):
                runner.verify_matrix(Driver(), stream, ["sample"], "1.8.1", "d", "driver")
        self.assertEqual(len(stream.getvalue().splitlines()), 1)
