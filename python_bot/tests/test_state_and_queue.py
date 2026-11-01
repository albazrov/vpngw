import os

from vpngw_bot.queue import JobQueue
from vpngw_bot.state import BotState


def test_queue_round_trip(tmp_path):
    db_path = tmp_path / "jobs.db"
    q = JobQueue(str(db_path))
    q.enqueue("status", {"chat_id": 1})
    job = q.next_pending()
    assert job is not None
    assert job["action"] == "status"
    q.complete(job["job_id"], {"status": "ok"})
    pending = q.next_pending()
    assert pending is None


def test_state_offset_persistence(tmp_path):
    db_path = tmp_path / "state.db"
    state = BotState(str(db_path))
    state.set_offset(42)
    assert state.get_offset() == 42
    state.set_offset(99)
    assert state.get_offset() == 99
