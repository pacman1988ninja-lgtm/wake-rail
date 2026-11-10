import json
import os
import sqlite3
from pathlib import Path

DB_PATH = os.environ.get("KIMI_ORDERS_DB", "C:/kimi-work/dispatcher-limited/orders.db")
TARGET_OVERRIDE = os.environ.get("KIMI_ORDERS_TARGET_OVERRIDE", "")
KINDS = ("assign",)


def target_for(assignee):
    assignee = (assignee or "").strip()
    if "/Исполнитель/" not in assignee:
        return ""
    parts = assignee.split("/")
    if len(parts) > 1 and parts[1] == "Инфра" and parts[-1] == "Web":
        assignee = assignee[:-3] + "Web-1"
    return assignee + " - Kimi"


def read_events():
    placeholders = ",".join("?" for _ in KINDS)
    query = (
        "SELECT d.order_id, d.decision_no, d.kind, d.created_ts, o.assignee "
        "FROM decisions d JOIN orders o ON o.id = d.order_id "
        "WHERE d.kind IN (" + placeholders + ") "
        "ORDER BY d.created_ts, d.order_id, d.decision_no"
    )
    db = sqlite3.connect("file:" + Path(DB_PATH).as_posix() + "?mode=ro", uri=True)
    try:
        rows = db.execute(query, KINDS).fetchall()
    finally:
        db.close()
    events = []
    for order_id, decision_no, decision_kind, created_ts, assignee in rows:
        kind = "postanovka"
        events.append({
            "key": order_id + "|" + kind + "|" + str(decision_no),
            "order_id": order_id,
            "kind": kind,
            "decision_no": decision_no,
            "created_ts": created_ts,
            "contour": (assignee or "").split("/")[1] if "/" in (assignee or "") else "",
            "target_title": TARGET_OVERRIDE or target_for(assignee),
        })
    return events


if __name__ == "__main__":
    print(json.dumps(read_events(), ensure_ascii=True, separators=(",", ":")))
