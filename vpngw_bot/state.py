"""SQLite-backed state for Telegram offset and bot jobs."""

from __future__ import annotations

import json
import sqlite3
from typing import Any


class BotState:
    """Persist Telegram offset and small job metadata in SQLite."""

    def __init__(self, db_path: str = "/var/lib/vpngw/bot_state.db"):
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
                CREATE TABLE IF NOT EXISTS offsets (
                    key TEXT PRIMARY KEY,
                    value INTEGER NOT NULL
                )
                """
            )
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS jobs (
                    job_id TEXT PRIMARY KEY,
                    action TEXT NOT NULL,
                    payload TEXT NOT NULL,
                    status TEXT NOT NULL,
                    result TEXT,
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP
                )
                """
            )
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS speed_profiles (
                    profile_id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    url TEXT NOT NULL,
                    connect_timeout INTEGER NOT NULL,
                    max_time INTEGER NOT NULL,
                    created_by INTEGER NOT NULL,
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP
                )
                """
            )
            conn.commit()

    def add_speed_profile(
        self,
        profile_id: str,
        name: str,
        url: str,
        connect_timeout: int,
        max_time: int,
        created_by: int,
    ) -> None:
        with self._connect() as conn:
            conn.execute(
                "INSERT INTO speed_profiles(profile_id, name, url, connect_timeout, max_time, created_by) "
                "VALUES(?, ?, ?, ?, ?, ?)",
                (profile_id, name, url, connect_timeout, max_time, created_by),
            )
            conn.commit()

    def list_speed_profiles(self) -> list[dict[str, Any]]:
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT profile_id, name, url, connect_timeout, max_time FROM speed_profiles ORDER BY created_at, profile_id"
            ).fetchall()
            return [
                {
                    "id": row["profile_id"],
                    "name": row["name"],
                    "url": row["url"],
                    "connect_timeout": row["connect_timeout"],
                    "max_time": row["max_time"],
                }
                for row in rows
            ]

    def get_speed_profile(self, profile_id: str) -> dict[str, Any] | None:
        with self._connect() as conn:
            row = conn.execute(
                "SELECT profile_id, name, url, connect_timeout, max_time FROM speed_profiles WHERE profile_id = ?",
                (profile_id,),
            ).fetchone()
            if row is None:
                return None
            return {
                "id": row["profile_id"],
                "name": row["name"],
                "url": row["url"],
                "connect_timeout": row["connect_timeout"],
                "max_time": row["max_time"],
            }

    def set_offset(self, value: int, key: str = "telegram") -> None:
        with self._connect() as conn:
            conn.execute(
                "INSERT INTO offsets(key, value) VALUES(?, ?) "
                "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                (key, int(value)),
            )
            conn.commit()

    def get_offset(self, key: str = "telegram") -> int:
        with self._connect() as conn:
            row = conn.execute("SELECT value FROM offsets WHERE key = ?", (key,)).fetchone()
            return int(row["value"]) if row else 0

    def save_job(self, job_id: str, action: str, payload: dict[str, Any], status: str = "queued", result: str | None = None) -> None:
        with self._connect() as conn:
            conn.execute(
                "INSERT INTO jobs(job_id, action, payload, status, result) VALUES(?, ?, ?, ?, ?) "
                "ON CONFLICT(job_id) DO UPDATE SET action=excluded.action, payload=excluded.payload, status=excluded.status, result=excluded.result",
                (job_id, action, json.dumps(payload, sort_keys=True), status, result),
            )
            conn.commit()

    def get_job(self, job_id: str) -> dict[str, Any] | None:
        with self._connect() as conn:
            row = conn.execute("SELECT * FROM jobs WHERE job_id = ?", (job_id,)).fetchone()
            if row is None:
                return None
            return {
                "job_id": row["job_id"],
                "action": row["action"],
                "payload": json.loads(row["payload"]),
                "status": row["status"],
                "result": row["result"],
            }

    def update_job_status(self, job_id: str, status: str, result: str | None = None) -> None:
        self.save_job(job_id, self.get_job(job_id)["action"], self.get_job(job_id)["payload"], status, result) if self.get_job(job_id) else None
