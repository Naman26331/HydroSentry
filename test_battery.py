"""HydroSentry Comprehensive Local Integration & Edge-Case Verification Suite
Lead QA & Distributed Systems Verification Harness
"""
from __future__ import annotations

import json
import os
import sys
from decimal import Decimal as D
from unittest.mock import MagicMock

# Mock boto3 for local offline harness if not installed
if "boto3" not in sys.modules:
    mock_boto = MagicMock()
    sys.modules["boto3"] = mock_boto

# Import core modules
from compute import SinkProfile, HazardResult, compute_hazard, authorize, _evaluate_cedar_policy
from src.app import lambda_handler, SINK_PROFILES

def run_suite():
    results = []

    # -------------------------------------------------------------------------
    # DIRECTIVE 1: Credential & Environment Audit
    # -------------------------------------------------------------------------
    env_file_exists = os.path.exists(".env")
    env_json_exists = os.path.exists("env.json")
    aws_key_in_env = any(k in os.environ for k in ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"])
    
    # Check env.json content
    env_json_content = {}
    if env_json_exists:
        with open("env.json", "r") as f:
            env_json_content = json.load(f)
    
    compute_env = env_json_content.get("ComputeFunction", {}).get("ENVIRONMENT", "UNKNOWN")
    endpoint_url = env_json_content.get("ComputeFunction", {}).get("AWS_ENDPOINT_URL", "UNKNOWN")

    audit_status = (
        not env_file_exists and
        not aws_key_in_env and
        compute_env == "LOCAL"
    )

    results.append({
        "name": "Audit: Credential & Environment Binding",
        "inputs": "Inspect .env, env.json, os.environ",
        "expected": "LOCAL emulator binding, no committed/live AWS credentials",
        "actual": f"ENVIRONMENT={compute_env}, Endpoint={endpoint_url}, LiveKeys={aws_key_in_env}",
        "passed": audit_status
    })

    # -------------------------------------------------------------------------
    # DIRECTIVE 2: Physical & Hydrological Edge Cases
    # -------------------------------------------------------------------------
    minto_profile = SinkProfile(
        catchment_area_m2=D("48500"),
        runoff_coeff=D("0.92"),
        baseline_drainage_m3hr=D("120"),
        critical_volume_m3=D("1850"),
        critical_depth_cm=D("35.0")
    )

    prahladpur_profile = SinkProfile(
        catchment_area_m2=D("62000"),
        runoff_coeff=D("0.90"),
        baseline_drainage_m3hr=D("95"),
        critical_volume_m3=D("2400"),
        critical_depth_cm=D("35.0")
    )

    # Edge Case A: Zero Rain
    res_a = compute_hazard(minto_profile, D("0"))
    auth_a = authorize(res_a)
    passed_a = (
        res_a.active is False and
        res_a.volume_m3 == D("0.00") and
        res_a.depth_cm == D("0.00") and
        res_a.tts_min is None and
        auth_a == "DISPATCH_DENIED"
    )
    results.append({
        "name": "Edge Case A: Zero Rain / Bone Dry",
        "inputs": "Rainfall = 0 mm/hr (Minto Bridge)",
        "expected": "Inflow=0, Net<=0, Depth=0 mm, TTS=Infinity, Active=False, Auth=DENIED",
        "actual": f"Inflow=0, Net=-120, Depth={res_a.cedar_depth_mm}mm, TTS={res_a.tts_min}, Active={res_a.active}, Auth={auth_a}",
        "passed": passed_a
    })

    # Edge Case B: Equilibrium Inflow
    # Inflow = rainfall / 1000 * 48500 * 0.92 = 120 => rainfall = 120 / (48.5 * 0.92)
    eq_rain = D("120") / (D("48500") / D("1000") * D("0.92"))
    res_b = compute_hazard(minto_profile, eq_rain)
    auth_b = authorize(res_b)
    passed_b = (
        res_b.active is False and
        res_b.volume_m3 == D("0.00") and
        res_b.depth_cm == D("0.00") and
        res_b.tts_min is None and
        auth_b == "DISPATCH_DENIED"
    )
    results.append({
        "name": "Edge Case B: Equilibrium Inflow",
        "inputs": f"Rainfall = {eq_rain.quantize(D('0.0001'))} mm/hr (Inflow = 120 m3/hr)",
        "expected": "Net Accumulation=0, Depth=0 mm, TTS=Infinity, Auth=DENIED",
        "actual": f"Net=0.00, Depth={res_b.cedar_depth_mm}mm, TTS={res_b.tts_min}, Active={res_b.active}, Auth={auth_b}",
        "passed": passed_b
    })

    # Edge Case C: Moderate Rain (25 mm/hr)
    res_c_15 = compute_hazard(minto_profile, D("25"), storm_duration_min=15)
    res_c_30 = compute_hazard(minto_profile, D("25"), storm_duration_min=30)
    auth_c = authorize(res_c_15)
    # At 25 mm/hr: net = 1115.5 - 120 = 995.5 m3/hr > 0 (inflow exceeds drain)
    # Over 30 mins: volume = 995.5 * 30 / 60 = 497.75 m3 -> depth = 497.75 / 1850 * 35 = 9.42 cm (94 mm < 350 mm)
    passed_c = (
        res_c_30.cedar_depth_mm < 350 and
        res_c_30.cedar_tts_min > 30 and
        auth_c == "DISPATCH_DENIED"
    )
    results.append({
        "name": "Edge Case C: Moderate Rain / Under-Threshold",
        "inputs": "Rainfall = 25 mm/hr (Minto Bridge, 30 min horizon)",
        "expected": "Inflow > Drain, Depth(30m) < 350 mm, Auth=DENIED",
        "actual": f"Net=995.5 m3/hr, Depth(30m)={res_c_30.cedar_depth_mm}mm, TTS={res_c_30.cedar_tts_min}m, Auth={auth_c}",
        "passed": passed_c
    })

    # Edge Case D: Catastrophic Cloudburst (200 mm/hr Pul Prahladpur)
    res_d = compute_hazard(prahladpur_profile, D("200"))
    auth_d = authorize(res_d)
    # Check what actual formula produces
    # In compute.py: raw_volume = min(cap, net * duration / 60), so depth is capped at 350 mm (critical_depth_cm).
    # tts = 2400 / 11065 * 60 = 13.01 min
    # horsepower = 11065 * 5 / 270 / 1 = 204.91 HP
    passed_d_scaled = (
        res_d.active is True and
        res_d.horsepower > D("60") and
        auth_d == "DISPATCH_AUTHORIZED"
    )
    # Note discrepancy with prompt's speculative bounds (Depth > 450mm, TTS < 10m vs model cap at 350mm, TTS=13.01m)
    depth_exceeds_450 = res_d.cedar_depth_mm > 450
    tts_under_10 = res_d.cedar_tts_min < 10
    passed_d = passed_d_scaled and depth_exceeds_450 and tts_under_10

    results.append({
        "name": "Edge Case D: Catastrophic Cloudburst (200 mm/hr)",
        "inputs": "Rainfall = 200 mm/hr (Pul Prahladpur)",
        "expected": "TTS < 10m, Depth > 450mm, HP > 60, Auth=ALLOWED",
        "actual": f"TTS={res_d.tts_min}m, Depth={res_d.cedar_depth_mm}mm (cap@350), HP={res_d.horsepower}, Auth={auth_d}",
        "passed": passed_d
    })

    # Edge Case E: Malformed Payload / Unknown Sink
    mock_event = {
        "requestContext": {"http": {"method": "POST", "path": "/telemetry/rainfall"}},
        "body": json.dumps({"sink_id": "Unknown_Underpass_999", "rainfall_mm_hr": 50})
    }
    resp_e = lambda_handler(mock_event, None)
    body_e = json.loads(resp_e.get("body", "{}"))
    passed_e = (
        resp_e.get("statusCode") in [400, 404] and
        "error" in body_e and
        not any(v in str(body_e).lower() for v in ["nan", "null pointer", "traceback"])
    )
    results.append({
        "name": "Edge Case E: Malformed Payload / Unknown Sink",
        "inputs": "sink_id='Unknown_Underpass_999'",
        "expected": "Structured error (400/404), zero crash/NaN",
        "actual": f"HTTP {resp_e.get('statusCode')}: {body_e}",
        "passed": passed_e
    })

    # -------------------------------------------------------------------------
    # DIRECTIVE 3: Cedar Policy Boundary-Condition Verification
    # -------------------------------------------------------------------------
    # Sub-case 1: depth = 349, tts = 20
    ctx_1 = {"hazard_active": True, "depth_mm": 349, "tts_min": 20}
    auth_1 = "DISPATCH_AUTHORIZED" if _evaluate_cedar_policy(ctx_1) else "DISPATCH_DENIED"
    passed_sub1 = (auth_1 == "DISPATCH_DENIED")
    results.append({
        "name": "Cedar Boundary 1: Off-by-one Below Threshold",
        "inputs": "water_depth_mm=349, time_to_submersion_mins=20",
        "expected": "DISPATCH_DENIED (depth < 350 mm)",
        "actual": f"{auth_1}",
        "passed": passed_sub1
    })

    # Sub-case 2: depth = 350, tts = 20
    ctx_2 = {"hazard_active": True, "depth_mm": 350, "tts_min": 20}
    auth_2 = "DISPATCH_AUTHORIZED" if _evaluate_cedar_policy(ctx_2) else "DISPATCH_DENIED"
    passed_sub2 = (auth_2 == "DISPATCH_AUTHORIZED")
    results.append({
        "name": "Cedar Boundary 2: Exact Critical Threshold",
        "inputs": "water_depth_mm=350, time_to_submersion_mins=20",
        "expected": "DISPATCH_AUTHORIZED (depth >= 350 && tts <= 30)",
        "actual": f"{auth_2}",
        "passed": passed_sub2
    })

    # Sub-case 3: depth = 400, tts = 31
    ctx_3 = {"hazard_active": True, "depth_mm": 400, "tts_min": 31}
    auth_3 = "DISPATCH_AUTHORIZED" if _evaluate_cedar_policy(ctx_3) else "DISPATCH_DENIED"
    passed_sub3 = (auth_3 == "DISPATCH_DENIED")
    results.append({
        "name": "Cedar Boundary 3: Horizon Exceeded",
        "inputs": "water_depth_mm=400, time_to_submersion_mins=31",
        "expected": "DISPATCH_DENIED (tts > 30 min window)",
        "actual": f"{auth_3}",
        "passed": passed_sub3
    })

    # -------------------------------------------------------------------------
    # DIRECTIVE 4: Frontend & Route Deflection Sanity Check
    # -------------------------------------------------------------------------
    with open("console.html", "r", encoding="utf-8") as f:
        console_code = f.read()

    has_payload_parse = "cedar_authorization" in console_code and "fetchSink" in console_code
    has_red_hazard = '#d93025' in console_code and 'radius:260' in console_code
    has_bypass_route = 'BYPASS' in console_code and '#188038' in console_code

    # Check detour coordinate safety: Minto basin is [28.63361, 77.21722]
    # MAIN passes directly through [28.6336, 77.2172].
    # BYPASS points deflect to [28.6304,77.2209], [28.6289,77.2254], [28.6258,77.2340]
    bypass_deflects = (
        "[28.6336,77.2172]" in console_code and
        "[28.6304,77.2209]" in console_code
    )

    passed_fe = has_payload_parse and has_red_hazard and has_bypass_route and bypass_deflects
    results.append({
        "name": "Frontend: Hazard Parsing & Route Deflection",
        "inputs": "console.html payload handling & Leaflet route layers",
        "expected": "Parses cedar_authorization; Red 260m hazard; Green bypass deflection",
        "actual": f"Parse={has_payload_parse}, RedCircle={has_red_hazard}, Bypass={has_bypass_route}, SafeDeflection={bypass_deflects}",
        "passed": passed_fe
    })

    return results

if __name__ == "__main__":
    test_results = run_suite()
    print("=" * 105)
    print(f"{'TEST NAME':<35} | {'STATUS':<6} | {'ACTUAL OUTPUT'}")
    print("=" * 105)
    for r in test_results:
        status = "PASS" if r["passed"] else "FAIL"
        print(f"{r['name']:<35} | {status:<6} | {r['actual']}")
    print("=" * 105)
