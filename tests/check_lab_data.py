#!/usr/bin/env python3
"""Run web/live/lab_data.sql through the live server's data path and check
that the JSON has the shape the dashboard expects. Exits non-zero on the
first problem.

    PGDATABASE=lab_test python tests/check_lab_data.py
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "web", "live"))
import server  # noqa: E402

ARRAYS = ("people", "probes", "pipelines", "storageRoots", "species", "projects",
          "projectMembers", "projectArtifacts", "subjects", "sessions", "events",
          "artifacts", "eventInputs", "eventTypeMeta", "roleMeta")


def fail(msg):
    sys.exit("check_lab_data: " + msg)


data = json.loads(server.fetch_lab_data(server.SQL))
expected = set(ARRAYS) | {"NOW"}
if set(data) != expected:
    fail("keys differ: missing %s, extra %s"
         % (sorted(expected - set(data)), sorted(set(data) - expected)))
for key in ARRAYS:
    if not isinstance(data[key], list):
        fail("%s is not an array" % key)
if not isinstance(data["NOW"], (int, float)):
    fail("NOW is not a number")
for e in data["events"]:
    if not isinstance(e.get("detail"), dict):
        fail("event %s has no detail object" % e.get("event_id"))
    if not str(e.get("occurred_at", "")).endswith("Z"):
        fail("event %s occurred_at is not UTC ISO-8601" % e.get("event_id"))
for a in data["artifacts"]:
    if not isinstance(a.get("verification"), dict) or "status" not in a["verification"]:
        fail("artifact %s has no verification status" % a.get("artifact_id"))
print("check_lab_data: OK (%d events, %d artifacts)"
      % (len(data["events"]), len(data["artifacts"])))
