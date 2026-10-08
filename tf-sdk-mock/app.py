import json
import os
import subprocess

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

ROLLOUT_TIMEOUT = os.getenv("ROLLOUT_TIMEOUT", "90s")
# control_path_ref=kubeconfig pairs, e.g. "k3s-local=/kube/local.yaml". Unknown refs use $KUBECONFIG.
KUBECONFIGS = dict(
    pair.split("=", 1) for pair in os.getenv("KUBECONFIGS", "").split(",") if "=" in pair
)

app = FastAPI(title="tf-sdk-mock")


class DeployRequest(BaseModel):
    operation_id: str
    namespace: str
    name: str
    image: str
    ports: list[int] = Field(default_factory=lambda: [80])
    replicas: int = 1
    control_path_ref: str | None = None
    labels: dict[str, str] = Field(default_factory=dict)


class TerminateRequest(BaseModel):
    operation_id: str
    namespace: str
    control_path_ref: str | None = None


def _kubectl(args: list[str], control_path_ref: str | None, stdin: str | None = None) -> str:
    env = dict(os.environ)
    if control_path_ref in KUBECONFIGS:
        env["KUBECONFIG"] = KUBECONFIGS[control_path_ref]
    done = subprocess.run(
        ["kubectl", *args], input=stdin, env=env, capture_output=True, text=True, check=False
    )
    if done.returncode != 0:
        raise HTTPException(502, detail=f"kubectl {args[0]} failed: {done.stderr.strip()[:400]}")
    return done.stdout


def _manifest(req: DeployRequest) -> str:
    labels = {"app": req.name, **{k: _label(v) for k, v in req.labels.items()}}
    ports = [{"name": f"p{port}", "port": port, "targetPort": port} for port in req.ports]
    items = [
        {"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": req.namespace}},
        {
            "apiVersion": "apps/v1",
            "kind": "Deployment",
            "metadata": {"name": req.name, "namespace": req.namespace, "labels": labels},
            "spec": {
                "replicas": req.replicas,
                "selector": {"matchLabels": {"app": req.name}},
                "template": {
                    "metadata": {"labels": labels},
                    "spec": {
                        "containers": [
                            {
                                "name": req.name,
                                "image": req.image,
                                "ports": [{"containerPort": port} for port in req.ports],
                            }
                        ]
                    },
                },
            },
        },
        {
            "apiVersion": "v1",
            "kind": "Service",
            "metadata": {"name": req.name, "namespace": req.namespace, "labels": labels},
            "spec": {"selector": {"app": req.name}, "ports": ports},
        },
    ]
    return json.dumps({"apiVersion": "v1", "kind": "List", "items": items})


def _label(value: str) -> str:
    # Kubernetes label values allow at most 63 chars of [A-Za-z0-9-_.].
    cleaned = "".join(ch if ch.isalnum() or ch in "-_." else "-" for ch in value)
    return cleaned[:63].strip("-_.")


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


def _dns_label(name: str) -> str:
    # Service names are DNS-1035 labels and must start with a letter; SRM may pass a UUID
    return name if name[:1].isalpha() else f"app-{name}"[:63].rstrip("-")


@app.post("/v1/deploy")
def deploy(req: DeployRequest) -> dict[str, object]:
    req = req.model_copy(update={"name": _dns_label(req.name)})
    _kubectl(["apply", "-f", "-"], req.control_path_ref, stdin=_manifest(req))
    _kubectl(
        ["rollout", "status", f"deployment/{req.name}", "-n", req.namespace,
         f"--timeout={ROLLOUT_TIMEOUT}"],
        req.control_path_ref,
    )
    fqdn = f"{req.name}.{req.namespace}.svc.cluster.local"
    return {
        "status": "active",
        "external_id": f"{req.namespace}/{req.name}",
        "external_ref": f"{req.namespace}/deployment/{req.name}",
        "endpoints": [{"interface_id": f"p{port}", "fqdn": fqdn, "port": port} for port in req.ports],
    }


@app.post("/v1/terminate")
def terminate(req: TerminateRequest) -> dict[str, str]:
    _kubectl(
        ["delete", "namespace", req.namespace, "--ignore-not-found", "--wait=false"],
        req.control_path_ref,
    )
    return {"status": "terminated"}
