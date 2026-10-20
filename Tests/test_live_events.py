"""Tests for opt-in desktop progress events."""

import json
import os
import unittest
from contextlib import redirect_stdout
from io import StringIO
from unittest.mock import patch

from HRTFCalculation.LiveEvents import EVENT_PREFIX, emit_live_event


class LiveEventTests(unittest.TestCase):
    def test_events_are_silent_for_cli_runs(self):
        with patch.dict(os.environ, {}, clear=True), redirect_stdout(StringIO()) as output:
            emit_live_event("Cropping left ear")
        self.assertEqual(output.getvalue(), "")

    def test_desktop_event_is_structured_and_flushed_as_one_line(self):
        with patch.dict(os.environ, {"PINNA2HRTF_LIVE_EVENTS": "1"}), redirect_stdout(StringIO()) as output:
            emit_live_event("Completed 2 of 8 steps", key="numcalc-progress", level="warning")
        line = output.getvalue().strip()
        self.assertTrue(line.startswith(EVENT_PREFIX))
        event = json.loads(line[len(EVENT_PREFIX):])
        self.assertEqual(event, {"message": "Completed 2 of 8 steps", "level": "warning", "key": "numcalc-progress"})


if __name__ == "__main__":
    unittest.main()
