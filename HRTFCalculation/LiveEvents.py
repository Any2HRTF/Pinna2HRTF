"""Small, opt-in progress events for the desktop application's live timeline."""

import json
import os


EVENT_PREFIX = "@@PINNA2HRTF_EVENT@@"


def emit_live_event(message: str, *, key: str | None = None, level: str = "info") -> None:
    """Emit a machine-readable event only when launched by the desktop app."""
    if os.environ.get("PINNA2HRTF_LIVE_EVENTS") != "1":
        return
    event = {"message": message, "level": level}
    if key is not None:
        event["key"] = key
    print(EVENT_PREFIX + json.dumps(event, ensure_ascii=False, separators=(",", ":")), flush=True)
