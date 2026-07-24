#!/usr/bin/env python3
"""Strict validation for the persistent Palworld operating policy."""

from __future__ import annotations

import json
import math
import sys
from datetime import datetime
from pathlib import Path
from typing import Any


POLICY_OVERRIDES = frozenset({"auto", "started", "stopped"})
MAX_POLICY_FILE_BYTES = 64 * 1024


class PolicyFileError(RuntimeError):
    """The persistent operating policy exists but cannot be trusted."""


def _policy_json_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    record: dict[str, Any] = {}
    for key, value in pairs:
        if key in record:
            raise PolicyFileError(f"duplicate JSON field: {key}")
        record[key] = value
    return record


def read_policy_file(path: Path) -> dict[str, Any]:
    """Read and strictly validate one persistent supervisor policy file."""
    try:
        with path.open("rb") as handle:
            payload = handle.read(MAX_POLICY_FILE_BYTES + 1)
    except FileNotFoundError as error:
        raise PolicyFileError("operating policy file is missing") from error
    except OSError as error:
        detail = error.strerror or error.__class__.__name__
        raise PolicyFileError(f"operating policy file is unreadable: {detail[:120]}") from error
    if len(payload) > MAX_POLICY_FILE_BYTES:
        raise PolicyFileError("operating policy file exceeds the 64 KiB safety limit")
    try:
        content = payload.decode("utf-8")
    except UnicodeDecodeError as error:
        raise PolicyFileError("operating policy file is not valid UTF-8") from error
    try:
        record = json.loads(content, object_pairs_hook=_policy_json_object)
    except PolicyFileError:
        raise
    except json.JSONDecodeError as error:
        raise PolicyFileError(
            f"operating policy JSON is invalid at line {error.lineno}, column {error.colno}"
        ) from error
    if not isinstance(record, dict):
        raise PolicyFileError("operating policy JSON must be an object")

    override = record.get("override")
    if override not in POLICY_OVERRIDES:
        raise PolicyFileError("operating policy override must be auto, started, or stopped")

    has_until_epoch = "until_epoch" in record
    has_until_at = "until_at" in record
    if override == "auto" and (has_until_epoch or has_until_at):
        raise PolicyFileError("automatic policy must not contain an expiration")
    if has_until_epoch != has_until_at:
        raise PolicyFileError("policy expiration requires both until_epoch and until_at")
    if has_until_epoch:
        until_epoch = record["until_epoch"]
        if (
            isinstance(until_epoch, bool)
            or not isinstance(until_epoch, (int, float))
            or not math.isfinite(float(until_epoch))
        ):
            raise PolicyFileError("policy until_epoch must be a finite number")
        until_at = record["until_at"]
        if not isinstance(until_at, str) or not until_at.strip():
            raise PolicyFileError("policy until_at must be an ISO timestamp")
        try:
            parsed_until = datetime.fromisoformat(until_at)
        except (ValueError, OverflowError, OSError) as error:
            raise PolicyFileError("policy until_at must be an ISO timestamp") from error
        if parsed_until.tzinfo is None or parsed_until.utcoffset() is None:
            raise PolicyFileError("policy until_at must include a UTC offset")
        try:
            timestamp_difference = abs(parsed_until.timestamp() - float(until_epoch))
        except (OverflowError, OSError, ValueError) as error:
            raise PolicyFileError("policy expiration timestamp is outside the supported range") from error
        if timestamp_difference >= 1.0:
            raise PolicyFileError("policy until_at does not match until_epoch")
    return record


def main(argv: list[str] | None = None) -> int:
    arguments = sys.argv[1:] if argv is None else argv
    if len(arguments) != 1:
        print("usage: policy.py POLICY_FILE", file=sys.stderr)
        return 2
    try:
        read_policy_file(Path(arguments[0]))
    except PolicyFileError as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
