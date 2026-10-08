-- One deployable zone for SRM: zone -> compute domain -> deploy_workload capability ->
-- control-path binding. SRM has no topology bootstrap yet, so the harness writes these rows.
-- Safe to re-run: every insert is keyed on the table's unique ref.
--
-- psql variables:
--   zone_id           fixed UUID, the id OEG, FM agreements and e2e scripts use
--   zone_ref          stable text id, e.g. k3s-local
--   zone_name         shown to App Providers as edgeCloudZoneName
--   region            shown as edgeCloudRegion, matched by the region filter
--   provider          shown as edgeCloudProvider
--   control_path_ref  sent to tf-sdk-mock with every deploy, picks the cluster

BEGIN;

INSERT INTO zone (id, ref, name, kind, state, metadata)
VALUES (
    :'zone_id', :'zone_ref', :'zone_name', 'resource', 'active',
    jsonb_build_object('provider', :'provider', 'location', jsonb_build_object('region', :'region'))
)
ON CONFLICT (ref) DO UPDATE
    SET name = EXCLUDED.name, state = EXCLUDED.state, metadata = EXCLUDED.metadata,
        updated_at = now();

INSERT INTO domain (zone_id, ref, name, kind, state, metadata)
SELECT id, :'zone_ref' || '-compute', :'zone_name' || ' compute', 'compute', 'active', '{}'::jsonb
FROM zone WHERE ref = :'zone_ref'
ON CONFLICT (zone_id, ref) DO UPDATE SET state = EXCLUDED.state, updated_at = now();

INSERT INTO capability (domain_id, ref, name, kind, state, metadata)
SELECT d.id, :'zone_ref' || '-deploy', 'Deploy workloads', 'deploy_workload', 'active', '{}'::jsonb
FROM domain d JOIN zone z ON z.id = d.zone_id
WHERE z.ref = :'zone_ref' AND d.ref = :'zone_ref' || '-compute'
ON CONFLICT (domain_id, ref) DO UPDATE SET state = EXCLUDED.state, updated_at = now();

INSERT INTO control_path_binding (
    capability_id, ref, control_path_ref, supported_runtime_kinds, supported_actions,
    priority, is_default, state, metadata
)
SELECT c.id, :'zone_ref' || '-tf-sdk-mock', :'control_path_ref',
       '["helm", "container", "k8s_manifest"]'::jsonb, '["deploy", "terminate"]'::jsonb,
       100, true, 'active', '{}'::jsonb
FROM capability c
JOIN domain d ON d.id = c.domain_id
JOIN zone z ON z.id = d.zone_id
WHERE z.ref = :'zone_ref' AND c.ref = :'zone_ref' || '-deploy'
ON CONFLICT (capability_id, ref) DO UPDATE
    SET control_path_ref = EXCLUDED.control_path_ref,
        supported_runtime_kinds = EXCLUDED.supported_runtime_kinds,
        supported_actions = EXCLUDED.supported_actions,
        state = EXCLUDED.state, updated_at = now();

COMMIT;
