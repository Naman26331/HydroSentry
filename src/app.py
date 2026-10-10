"""HydroSentry Compute Lambda -- Phase 3 stub."""


def lambda_handler(event, context):
    """Handler implementation deferred to Phase 3.

    Routes:
        POST /telemetry/rainfall  -- Ingest rainfall data, compute hazard
        GET  /hazards/active      -- Return active hazard states
    """
    return {
        "statusCode": 501,
        "body": '{"error": "Not Implemented -- awaiting Phase 3"}',
    }
