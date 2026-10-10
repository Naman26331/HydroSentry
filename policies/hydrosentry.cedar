// ============================================================================
// HydroSentry — Cedar Authorization Policy
//
// Policy: Automated Emergency Pump Dispatch
//
// Behaviour:
//   PERMIT the AutomatedSentinel role to dispatch an emergency pump to any
//   UrbanSink resource ONLY when BOTH conditions are satisfied:
//     1. water_depth_mm          >= 350   (axle-drowning threshold reached)
//     2. time_to_submersion_mins <= 30    (imminent submersion window)
//
// Security posture:
//   - Cedar's native default-deny architecture ensures that any request
//     not explicitly matched by this policy is DENIED.
//   - Zero wildcard permissions: principal, action, and resource are all
//     explicitly scoped.
//   - Context comparisons use Cedar Long (integer) types exclusively —
//     no floating-point operations.
// ============================================================================

permit (
    principal == HydroSentry::Role::"AutomatedSentinel",
    action    == HydroSentry::Action::"DispatchEmergencyPump",
    resource is HydroSentry::UrbanSink
)
when {
    context.water_depth_mm >= 350 &&
    context.time_to_submersion_mins <= 30
};
