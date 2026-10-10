"""HydroSentry Compute Lambda — Phase 4 implementation.

Routes:
    POST /telemetry/rainfall  — Ingest rainfall data, compute hazard, store, emit events
    GET  /hazards/active      — Return active hazard states from DynamoDB

Environment:
    TABLE_NAME      — DynamoDB table name (HydroSentry-HazardState)
    EVENT_BUS_NAME  — EventBridge bus name (HydroSentry-Bus)
    AWS_ENDPOINT_URL — Optional LocalStack endpoint
"""
from __future__ import annotations

import json
import os
import time
from decimal import Decimal, ROUND_HALF_UP

# ── boto3 import (available in Lambda runtime) ────────────────────────────────
import boto3

# ── Environment ───────────────────────────────────────────────────────────────
TABLE_NAME     = os.environ.get("TABLE_NAME", "HydroSentry-HazardState")
EVENT_BUS_NAME = os.environ.get("EVENT_BUS_NAME", "HydroSentry-Bus")
ENDPOINT_URL   = os.environ.get("AWS_ENDPOINT_URL", "")

# ── boto3 clients ─────────────────────────────────────────────────────────────
_client_kwargs = {}
if ENDPOINT_URL:
    _client_kwargs["endpoint_url"] = ENDPOINT_URL

dynamodb    = boto3.client("dynamodb", **_client_kwargs)
eventbridge = boto3.client("events",   **_client_kwargs)


# ── Sink Profiles (from data/delhi_sinks.yaml — Phase 0 seed) ────────────────
SINK_PROFILES = {
    "DELSNK001": {
        "name":                    "Minto Bridge Underpass",
        "catchment_area_m2":       Decimal("48500"),
        "runoff_coeff":            Decimal("0.92"),
        "baseline_drainage_m3hr":  Decimal("120"),
        "critical_volume_m3":      Decimal("1850"),
        "critical_depth_cm":       Decimal("35.0"),
    },
    "DELSNK002": {
        "name":                    "Pul Prahladpur Underpass",
        "catchment_area_m2":       Decimal("62000"),
        "runoff_coeff":            Decimal("0.90"),
        "baseline_drainage_m3hr":  Decimal("95"),
        "critical_volume_m3":      Decimal("2400"),
        "critical_depth_cm":       Decimal("35.0"),
    },
    "DELSNK003": {
        "name":                    "Zakhira Underpass",
        "catchment_area_m2":       Decimal("41200"),
        "runoff_coeff":            Decimal("0.88"),
        "baseline_drainage_m3hr":  Decimal("80"),
        "critical_volume_m3":      Decimal("1620"),
        "critical_depth_cm":       Decimal("35.0"),
    },
}

# ── Quantisation (mirrors compute.py) ────────────────────────────────────────
_TWO_DP   = Decimal("0.01")
_ZERO     = Decimal("0")
_ONE      = Decimal("1")
_TEN      = Decimal("10")
_SIXTY    = Decimal("60")
_THOUSAND = Decimal("1000")
_HP_DENOM = Decimal("270")

_DEPTH_THRESHOLD_MM = 350
_TTS_THRESHOLD_MIN  = 30


def _q(value: Decimal) -> Decimal:
    return value.quantize(_TWO_DP, rounding=ROUND_HALF_UP)


# ── Compute (identical to Phase 1 compute.py) ────────────────────────────────
def compute_hazard(profile: dict, rainfall_mm_hr: Decimal,
                   storm_duration_min: int = 15,
                   head_m: Decimal = Decimal("5.0"),
                   pump_efficiency: Decimal = Decimal("1.0")) -> dict:
    """Compute flood-hazard metrics for a single sink."""
    if rainfall_mm_hr < _ZERO:
        raise ValueError(f"rainfall_mm_hr must be >= 0, got {rainfall_mm_hr}")
    duration = Decimal(storm_duration_min)
    if duration <= _ZERO:
        raise ValueError(f"storm_duration_min must be > 0, got {storm_duration_min}")

    inflow = (rainfall_mm_hr / _THOUSAND
              * profile["catchment_area_m2"]
              * profile["runoff_coeff"])
    net = inflow - profile["baseline_drainage_m3hr"]

    if net <= _ZERO:
        return {
            "active": False, "tts_min": None,
            "volume_m3": _q(_ZERO), "depth_cm": _q(_ZERO),
            "horsepower": _q(_ZERO),
            "cedar_depth_mm": 0, "cedar_tts_min": -1,
        }

    cap = profile["critical_volume_m3"]
    raw_tts    = cap / net * _SIXTY
    raw_volume = min(cap, net * duration / _SIXTY)
    raw_depth  = raw_volume / cap * profile["critical_depth_cm"]
    raw_hp     = net * head_m / _HP_DENOM / pump_efficiency

    cedar_depth_mm = int(raw_depth * _TEN)
    cedar_tts_min  = int(raw_tts)

    return {
        "active": True,
        "tts_min": _q(raw_tts),
        "volume_m3": _q(raw_volume),
        "depth_cm": _q(raw_depth),
        "horsepower": _q(raw_hp),
        "cedar_depth_mm": cedar_depth_mm,
        "cedar_tts_min": cedar_tts_min,
    }


def cedar_authorize(result: dict) -> str:
    """Cedar mock: DISPATCH_AUTHORIZED or DISPATCH_DENIED."""
    try:
        if (result["active"] is True
                and isinstance(result["cedar_depth_mm"], int)
                and isinstance(result["cedar_tts_min"], int)
                and result["cedar_depth_mm"] >= _DEPTH_THRESHOLD_MM
                and result["cedar_tts_min"] <= _TTS_THRESHOLD_MIN):
            return "DISPATCH_AUTHORIZED"
        return "DISPATCH_DENIED"
    except Exception:
        return "DISPATCH_DENIED"


# ── Helper: Decimal-safe JSON encoder ────────────────────────────────────────
class _DecimalEncoder(json.JSONEncoder):
    def default(self, obj):
        if isinstance(obj, Decimal):
            # Return int for .00 values, else float-safe string representation
            if obj == obj.to_integral_value():
                return int(obj)
            return float(obj)
        return super().default(obj)


# ── Route: POST /telemetry/rainfall ──────────────────────────────────────────
def _handle_post_rainfall(body: dict) -> dict:
    sink_id       = body.get("sink_id", "")
    rainfall_mm_hr = body.get("rainfall_mm_hr")

    if sink_id not in SINK_PROFILES:
        return _response(400, {"error": f"Unknown sink_id: {sink_id}"})
    if rainfall_mm_hr is None:
        return _response(400, {"error": "Missing rainfall_mm_hr"})

    profile = SINK_PROFILES[sink_id]
    rain    = Decimal(str(rainfall_mm_hr))
    result  = compute_hazard(profile, rain)
    auth    = cedar_authorize(result)

    status = "HAZARD_ACTIVE" if result["active"] else "CLEAR"

    # Build response payload
    resp = {
        "sink_id":              sink_id,
        "status":               status,
        "depth_mm":             result["cedar_depth_mm"],
        "tts_min":              result["cedar_tts_min"] if result["active"] else None,
        "required_pump_hp":     float(_q(result["horsepower"])) if result["active"] else 0,
        "cedar_authorization":  auth,
    }

    # DynamoDB PutItem — store hazard state
    expires_at = int(time.time()) + 900  # 15-minute TTL
    item = {
        "sink_id":             {"S": sink_id},
        "status":              {"S": status},
        "depth_mm":            {"N": str(result["cedar_depth_mm"])},
        "tts_min":             {"N": str(result["cedar_tts_min"])},
        "required_pump_hp":    {"N": str(float(_q(result["horsepower"])))},
        "cedar_authorization": {"S": auth},
        "expires_at":          {"N": str(expires_at)},
    }
    dynamodb.put_item(TableName=TABLE_NAME, Item=item)

    # EventBridge — emit on DISPATCH_AUTHORIZED
    if auth == "DISPATCH_AUTHORIZED":
        event_detail = {
            "sink_id":   sink_id,
            "depth_mm":  result["cedar_depth_mm"],
            "tts_min":   result["cedar_tts_min"],
        }
        eventbridge.put_events(Entries=[{
            "Source":       "hydrosentry.engine",
            "DetailType":   "EmergencyDispatchAuthorized",
            "Detail":       json.dumps(event_detail),
            "EventBusName": EVENT_BUS_NAME,
        }])

    return _response(200, resp)


# ── Route: GET /hazards/active ───────────────────────────────────────────────
def _handle_get_hazards() -> dict:
    scan = dynamodb.scan(
        TableName=TABLE_NAME,
        # "status" is a DynamoDB reserved word -> alias it. Expired items are
        # filtered here because TTL deletion is lazy (up to ~48 h).
        FilterExpression="#s = :s AND expires_at > :now",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={
            ":s":   {"S": "HAZARD_ACTIVE"},
            ":now": {"N": str(int(time.time()))},
        },
    )
    hazards = []
    for item in scan.get("Items", []):
        hazards.append({
            "sink_id":             item["sink_id"]["S"],
            "status":              item["status"]["S"],
            "depth_mm":            int(item["depth_mm"]["N"]),
            "tts_min":             int(item["tts_min"]["N"]),
            "required_pump_hp":    float(item["required_pump_hp"]["N"]),
            "cedar_authorization": item["cedar_authorization"]["S"],
        })
    return _response(200, {"hazards": hazards})


# ── Response builder ─────────────────────────────────────────────────────────
def _response(code: int, body: dict) -> dict:
    return {
        "statusCode": code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body, cls=_DecimalEncoder),
    }


# ── Lambda entry point ──────────────────────────────────────────────────────
def lambda_handler(event, context):
    """Routes POST /telemetry/rainfall and GET /hazards/active."""
    method = event.get("requestContext", {}).get("http", {}).get("method", "")
    path   = event.get("requestContext", {}).get("http", {}).get("path", "")

    try:
        if method == "POST" and path == "/telemetry/rainfall":
            body = json.loads(event.get("body", "{}"))
            return _handle_post_rainfall(body)
        elif method == "GET" and path == "/hazards/active":
            return _handle_get_hazards()
        else:
            return _response(404, {"error": "Not found"})
    except Exception as exc:
        return _response(500, {"error": str(exc)})
