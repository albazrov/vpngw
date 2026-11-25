"""Durable job queue for Telegram actions."""

from __future__ import annotations

import json
import sqlite3
import uuid
from typing import Any


class JobQueue:
    """Simple persistent queue stored in SQLite."""

    def __init__(self, db_path: str = "/var/lib/vpngw/job_queue.db"):
        self.db_path = db_path
        self._init_db()

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row
        return conn

    def _init_db(self) -> None:
        with self._connect() as conn:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS jobs (
                    job_id TEXT PRIMARY KEY,
                    action TEXT NOT NULL,
                    payload TEXT NOT NULL,
                    status TEXT NOT NULL DEFAULT 'queued',
                    result TEXT,
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP
                )
                """
            )
            conn.commit()

    def enqueue(self, action: str, payload: dict[str, Any]) -> str:
        job_id = uuid.uuid4().hex
        with self._connect() as conn:
            conn.execute(
                "INSERT INTO jobs(job_id, action, payload, status) VALUES(?, ?, ?, 'queued')",
                (job_id, action, json.dumps(payload, sort_keys=True)),
            )
            conn.commit()
        return job_id

    def next_pending(self) -> dict[str, Any] | None:
        with self._connect() as conn:
            row = conn.execute(
                "SELECT * FROM jobs WHERE status = 'queued' ORDER BY created_at ASC LIMIT 1"
            ).fetchone()
            if row is None:
                return None
            return {
                "job_id": row["job_id"],
                "action": row["action"],
                "payload": json.loads(row["payload"]),
                "status": row["status"],
            }

    def complete(self, job_id: str, result: dict[str, Any] | str | None = None) -> None:
        with self._connect() as conn:
            conn.execute(
                "UPDATE jobs SET status = 'done', result = ? WHERE job_id = ?",
                (json.dumps(result, sort_keys=True) if isinstance(result, dict) else str(result), job_id),
            )
            conn.commit()

    def status(self, job_id: str) -> str:
        with self._connect() as conn:
            row = conn.execute("SELECT status, result FROM jobs WHERE job_id = ?", (job_id,)).fetchone()
            if row is None:
                return "missing"
            return row["status"]
