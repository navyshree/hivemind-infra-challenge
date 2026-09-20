# Hivemind Infrastructure Challenge — Greeter Service

A Go web service deployed to AWS on EKS, provisioned end to end with Terraform,
with a CI/CD pipeline and a documented production-readiness position.

---

## Contents

- [What was asked, and where it lives](#what-was-asked-and-where-it-lives)
- [Architecture](#architecture)
- [Repository layout](#repository-layout)
- [Prerequisites](#prerequisites)
- [Deploying](#deploying)
- [Using the service](#using-the-service)
- [CI/CD](#cicd)
- [Tearing down](#tearing-down)
- [Production readiness: what is implemented](#production-readiness-what-is-implemented)
- [Tradeoffs and compromises](#tradeoffs-and-compromises)
- [Cost](#cost)
- [Verification performed](#verification-performed)

---

## What was asked, and where it lives

| Requirement | Where |
|---|---|
| Deploy a web service to AWS using Terraform | [`terraform/`](terraform/) |
| Set `HELLO_TAG` to a unique value | [`k8s/base/greeter.env`](k8s/base/greeter.env), overwritten per-deploy by CD with the image tag |
| Add a URL parameter to the greeter | [`app/greeter.go`](app/greeter.go) — `?name=` |
| Highly available Kubernetes environment | EKS across 3 AZs; see [Architecture](#architecture) |
| CI/CD pipeline | [`.github/workflows/`](.github/workflows/) |
| Documentation | this file |
| Production-ready, with tradeoffs explained | [below](#tradeoffs-and-compromises) |

---

## Architecture

```
                            Internet
                                │
                    ┌───────────▼───────────┐
                    │   Application LB      │  created by the AWS Load Balancer
                    │   (3 public subnets)  │  Controller from the Ingress object
                    └───────────┬───────────┘
                                │  target-type: ip  (routes straight to pod IPs,
                                │                    which is what pod readiness
                                │                    gates require)
        ┌───────────────────────┼───────────────────────┐
        │                       │                       │
 ┌──────▼───────┐        ┌──────▼───────┐        ┌──────▼───────┐
 │    AZ  a     │        │    AZ  b     │        │    AZ  c     │
 │  ┌────────┐  │        │  ┌────────┐  │        │  ┌────────┐  │
 │  │  pod   │  │        │  │  pod   │  │        │  │  pod   │  │
 │  └────────┘  │        │  └────────┘  │        │  └────────┘  │
 │  EKS node    │        │  EKS node    │        │  EKS node    │
 │  private sn  │        │  private sn  │        │  private sn  │
 └──────┬───────┘        └──────┬───────┘        └──────┬───────┘
        │                       │                       │
 ┌──────▼───────┐        ┌──────▼───────┐        ┌──────▼───────┐
 │ NAT gateway  │        │ NAT gateway  │        │ NAT gateway  │  egress
 └──────────────┘        └──────────────┘        └──────────────┘
```

**What makes it highly available**

- Three AZs, with a **hard** `topologySpreadConstraint` on
  `topology.kubernetes.io/zone` (`whenUnsatisfiable: DoNotSchedule`). Replicas
  cannot all land in one AZ.
- One NAT gateway per AZ, so losing an AZ does not sever egress for the others.
- `maxUnavailable: 0` on the rolling update, plus ALB pod readiness gates: new
  pods must be passing target-group health checks before old ones retire.
- A `PodDisruptionBudget` keeps at least two replicas up during node drains and
  cluster upgrades.
- `HorizontalPodAutoscaler` with `minReplicas: 3` — never fewer than one per AZ.

**Zero-downtime deploys** depend on a chain that has to be correct end to end:
readiness gate → `maxUnavailable: 0` → `preStop` sleep (10s) → ALB
deregistration delay (20s) → `terminationGracePeriodSeconds` (40s) → the Go
server's own `Shutdown` drain (15s budget). Each window fits inside the next.

---

## Repository layout

```
app/                  Go service, tests, Dockerfile, lint config
terraform/            VPC, EKS, ECR, ALB controller, namespace, OIDC deploy role
k8s/base/             Kustomize base for the workload
.github/workflows/    ci.yml (validate everything) and cd.yml (build, push, deploy)
trivy.yaml            Shared scanner config, so local and CI agree
.trivyignore.yaml     Suppressions, each with a justification and an expiry
Makefile              Wrappers for the commands below
```

---

## Prerequisites

| Tool | Version used | Notes |
|---|---|---|
| Terraform | 1.16.3 | `>= 1.10` required |
| AWS CLI | v1.46 / v2 | credentials with permission to create VPC, EKS, IAM, ECR |
| kubectl | 1.37 | ships with kustomize 5.8.1 |
| Docker | 29.4 | only needed to build locally |
| Go | 1.27 | only needed to run tests outside Docker |

Verify credentials and note the expiry if they are temporary — an EKS apply
takes 15–25 minutes and a mid-apply expiry leaves partial state:

```shell
aws sts get-caller-identity
```

---

## Deploying

### 1. Infrastructure

```shell
cd terraform
terraform init
terraform apply
```

Roughly 20 minutes, most of it the EKS control plane and node group.

To wire up CI/CD at the same time, set your repository:

```shell
terraform apply -var 'github_repository=owner/repo'
```

Useful non-default variables:

| Variable | Default | Why you might change it |
|---|---|---|
| `region` | `eu-central-1` | |
| `kubernetes_version` | `1.36` | must stay in **standard** support — see the note below |
| `single_nat_gateway` | `false` | `true` saves ~USD 76/month, costs AZ-independent egress |
| `cluster_endpoint_public_access_cidrs` | `0.0.0.0/0` | narrow to known egress ranges |
| `github_repository` | `""` | enables the OIDC deploy role |

> **On `kubernetes_version`:** a cluster running a version in *extended* support
> is billed at **USD 0.60/cluster-hour instead of 0.10** — about USD 365/month
> extra for being out of date. As of 2026-09-20 standard support covers 1.34,
> 1.35 and 1.36 only; 1.33 and older are already in extended support. Re-check
> with `aws eks describe-cluster-versions` before applying, since this ages.

### 2. Workload

```shell
aws eks update-kubeconfig --region eu-central-1 --name hivemind-greeter
kubectl apply -k k8s/base
kubectl -n hivemind-greeter rollout status deployment/hivemind-greeter
```

### 3. Get the URL

```shell
kubectl -n hivemind-greeter get ingress hivemind-greeter \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

A freshly created ALB returns 503 for a minute or two while targets register.

---

## Using the service

```shell
curl "http://${ALB}/"
# Hello, 203.0.113.9! I'm hivemind-greeter-7d9c4f8b6c-x2kql (tag: sha-a1b2c3d4e5f6)

curl "http://${ALB}/?name=Ada"
# Hello, Ada! I'm hivemind-greeter-7d9c4f8b6c-x2kql (tag: sha-a1b2c3d4e5f6)

curl "http://${ALB}/healthz"
# ok
```

| Endpoint | Behaviour |
|---|---|
| `GET /` | greets the caller's IP, taken from the leftmost `X-Forwarded-For` entry |
| `GET /?name=X` | greets `X` |
| `GET /healthz`, `GET /readyz` | liveness and readiness probes |
| anything else | 404 |

The hostname in the reply is the pod name, so repeated calls show the ALB
spreading traffic across replicas. `HELLO_TAG` is the deployed image tag, so a
response identifies exactly which build served it.

**Handling of the `name` parameter.** It is caller-controlled and echoed back,
so it is trimmed, stripped of control characters (CR and LF in particular, which
would otherwise forge lines into the JSON logs), and truncated to 64 characters
by rune rather than by byte. The response is pinned to `text/plain` with
`X-Content-Type-Options: nosniff` so no user agent will parse it as markup.

---

## CI/CD

**`ci.yml`** runs on every push and pull request, in four parallel jobs:

| Job | What it does |
|---|---|
| `app` | `gofmt`, `go vet`, tests with `-race`, coverage floor, `golangci-lint` |
| `image` | builds the image, Trivy vulnerability + Dockerfile scan, then a **container smoke test** that asserts real HTTP responses and a clean SIGTERM drain |
| `terraform` | `fmt -check`, `validate`, `tflint`, Trivy misconfiguration scan |
| `manifests` | `kustomize build`, `kubeconform -strict`, Trivy scan of the rendered output |

**`cd.yml`** runs on pushes to `main` that touch `app/` or `k8s/`, and can be
dispatched manually with an `image_tag` input to roll back to any previously
built image.

- Authentication is **GitHub OIDC** — no long-lived AWS keys exist in the
  repository. The trust policy is scoped by `sub` to this repository and to
  `refs/heads/main` or the `production` environment.
- Images are tagged `sha-<commit>` into an **immutable** ECR repository, so a
  tag can never be repointed at different bytes.
- The deploy waits on `rollout status`, then smoke-tests through the ALB and
  asserts the response carries the tag it just deployed — so a green deploy
  means the new revision is genuinely serving traffic, not merely that
  `kubectl apply` returned 0.
- On failure it dumps pod status, deployment events and container logs.

After `terraform apply`, set the four repository variables it prints:

```shell
terraform output github_actions_variables
```

Tool versions in CI are pinned and installed from release tarballs rather than
pulled in as third-party actions, which keeps the number of actions holding the
job token small.

---

## Tearing down

**Order matters.** The ALB is created by the Load Balancer Controller in
response to the Ingress, so Terraform has no knowledge of it. Running
`terraform destroy` first leaves the ALB and its ENIs attached to the subnets,
and VPC deletion hangs until they are gone.

```shell
make destroy
```

or by hand:

```shell
kubectl delete -k k8s/base                      # removes the Ingress -> ALB
kubectl -n hivemind-greeter wait --for=delete ingress/hivemind-greeter --timeout=5m
cd terraform && terraform destroy
```

---

## Production readiness: what is implemented

**Container and supply chain**
- Multi-stage build to a `scratch` final image: **2.5 MiB, one layer, no shell,
  no package manager**. Trivy reports **0 vulnerabilities**.
- Static `CGO_ENABLED=0` binary, `-trimpath` so build-host paths do not leak.
- Runs as UID 65532, non-root, read-only root filesystem, all capabilities
  dropped, `seccompProfile: RuntimeDefault`, `allowPrivilegeEscalation: false`.
- Immutable ECR tags, scan-on-push, lifecycle expiry.
- Build provenance and SBOM attestations generated on push.

**Cluster**
- Nodes in private subnets only; nothing but the load balancers is public.
- IMDSv2 required with **hop limit 1**, so a compromised pod cannot reach
  instance metadata to steal the node role's credentials.
- Encrypted gp3 root volumes.
- EKS access entries (`authentication_mode = "API"`), not the `aws-auth`
  ConfigMap.
- Namespace enforces the `restricted` Pod Security Standard.
- Control plane logs (`api`, `audit`, `authenticator`) to CloudWatch, 30-day
  retention.
- IRSA for the Load Balancer Controller — no node-level AWS credentials.
- The CD role is scoped to **edit in one namespace**, not cluster admin.

**Application**
- Graceful shutdown on SIGTERM, verified: drains and exits 0 in 0.21s.
- Explicit server timeouts (read, write, idle) — Go's defaults are unlimited,
  which is a slow-client resource exhaustion vector.
- Structured JSON logs to stdout.
- Startup, liveness and readiness probes.
- Memory limit equals its request; **no CPU limit**, deliberately — see below.

---

## Tradeoffs and compromises

Ordered roughly by how much they would matter in a real production deployment.

### 1. Terraform state is local

A shared environment needs a remote backend with locking, or two engineers
applying concurrently will corrupt state. The S3 backend block is written and
commented in [`versions.tf`](terraform/versions.tf), using S3-native locking
(`use_lockfile`) rather than the older DynamoDB table.

It is left off because the bucket cannot live in the state that stores it — it
needs a bootstrap step, and for a single-operator review environment that is
ceremony without benefit.

### 2. No TLS

The ALB listens on HTTP/80 only. HTTPS needs a domain name and an ACM
certificate, neither of which this exercise provisions. **Traffic is
unencrypted in transit, which would be unacceptable in production.**

The exact annotations are written and commented in
[`k8s/base/ingress.yaml`](k8s/base/ingress.yaml): add `certificate-arn`, add 443
to `listen-ports`, set `ssl-redirect: "443"` and pin
`ELBSecurityPolicy-TLS13-1-2-2021-06`. With a domain in Route 53, cert-manager
or `external-dns` plus ACM would automate issuance and renewal.

### 3. The Kubernetes API endpoint is public

`cluster_endpoint_public_access_cidrs` defaults to `0.0.0.0/0`. GitHub-hosted
runners egress from a large, frequently rotated address range, and a reviewer
connects from an unknown network, so there is no narrower CIDR set that serves
both.

Mitigated but not solved: `authentication_mode = "API"` means reachability
alone grants nothing without an authenticated, explicitly authorised IAM
principal. The real fix is architectural — disable public access and reach the
API over PrivateLink from self-hosted runners or CodeBuild inside the VPC. That
needs CI infrastructure outside this exercise's scope. Recorded as an explicit,
expiring suppression in [`.trivyignore.yaml`](.trivyignore.yaml).

### 4. Unrestricted node egress

Nodes can reach any address outbound. Closing this properly means interface VPC
endpoints for ECR, S3, EKS, STS, CloudWatch Logs and EC2, then restricting
egress to those endpoint security groups — roughly a dozen endpoints at about
USD 7/month each. Correct for production; disproportionate here. Also recorded
as an expiring suppression.

### 5. No network policies

Any pod can talk to any other pod. The VPC CNI supports Kubernetes
`NetworkPolicy` enforcement, and a production deployment should default-deny
ingress in the namespace and permit only the ALB target-group traffic. Omitted
because with a single workload there is nothing to segment from — but that
argument stops holding the moment a second service is added.

### 6. Observability stops at logs and control-plane metrics

Structured JSON logs reach stdout, `metrics-server` backs the HPA, and control
plane logs reach CloudWatch. There is no application metrics endpoint, no
tracing, and no alerting.

Production would add a `/metrics` endpoint with RED metrics (rate, errors,
duration), scraped by the `amazon-cloudwatch-observability` addon or an
in-cluster Prometheus, OpenTelemetry tracing, and alerts on error rate and p99
latency. Fluent Bit would ship pod logs to a searchable store. This is the
single largest gap between "it runs" and "you can operate it at 3am".

### 7. Autoscaling is CPU-based

The HPA targets 70% CPU. For a service this cheap, CPU is a poor proxy for user
experience — it would scale on compute rather than on queueing. Requests per
second or p99 latency via KEDA would track what users actually feel. CPU is used
because it needs only `metrics-server`, which is a managed addon, where KEDA is
another component to install and operate.

Node-level autoscaling is also absent: the node group has `max_size = 6` but
nothing drives it. Karpenter is the current answer and would bin-pack better
than the Cluster Autoscaler.

### 8. No CPU limit on the container

Deliberate, and worth stating because it reads like an omission. A CPU limit is
enforced by CFS quota, which throttles the container even when the node is
otherwise idle, adding tail latency for no benefit. The CPU *request* already
guarantees the scheduler share. The memory limit is set and equals its request,
because memory is incompressible and a leak should be OOM-killed rather than
starve its neighbours.

### 9. Single environment

There is one Kustomize base and no overlays. A real deployment wants
`overlays/{dev,staging,prod}` differing in replica counts, resource sizing and
`cluster_endpoint_public_access_cidrs`, with Terraform workspaces or separate
state per environment. The layout is overlay-ready; the overlays are not
written.

### 10. Coverage floor is 40%

Unit coverage is 44.9%. The handler-level functions are 85–100% covered;
`main()` is ~20% of statements and cannot be meaningfully unit tested. Rather
than inflate the number with a contrived test, `main()` is covered by the
container smoke test in CI, which exercises startup, real HTTP serving and
SIGTERM handling against the actual image.

### 11. Actions pinned by tag, not commit SHA

Workflows reference `actions/checkout@v7` and similar. Tags are mutable; the
stricter supply-chain practice is pinning to a full commit SHA with Dependabot
to bump them. Tags are used here for readability. Third-party actions are
already kept to a minimum, with tools installed from pinned release tarballs.

### 12. No WAF, no DDoS protection beyond defaults

An internet-facing ALB in production would sit behind AWS WAF with at least the
managed common rule set and rate limiting. The Load Balancer Controller supports
this via `alb.ingress.kubernetes.io/wafv2-acl-arn`. Omitted as out of scope; it
is a single annotation plus the WAF ACL.

### 13. No secrets management

The service needs no secrets today, so none is wired up. When it does, the
answer is the External Secrets Operator or the Secrets Store CSI driver backed
by Secrets Manager or SSM Parameter Store — **not** Kubernetes `Secret` objects
committed to Git, which are base64, not encryption.

### 14. Single region

No cross-region DR. An AZ failure is survived; a region failure is not. Multi-
region for a stateless service means a second stack plus Route 53 latency or
failover routing — meaningful cost for a requirement that was not stated.

---

## Cost

Rates verified against the AWS Price List API for **eu-central-1**, 2026-09-20.

| Component | Rate | ~Monthly |
|---|---|---|
| EKS control plane | USD 0.10/hr | ~73 |
| NAT gateway × 3 | USD 0.052/hr each | ~114 + data |
| Application Load Balancer | USD 0.027/hr + LCU | ~20 |
| 3 × t3.medium on-demand | ~USD 0.048/hr each* | ~105 |
| **Total** | **~USD 0.43/hr** | **~310** |

\* The EC2 rate is approximate — it was not verified against the price list, unlike the others.

**Cheaper for a review environment:** `-var single_nat_gateway=true` removes two
NAT gateways (~USD 76/month) at the cost of AZ-independent egress. Spot capacity
for the node group would cut compute substantially for a stateless workload.

**Destroy the stack between sessions.** Left running, this is roughly
USD 10/day, and an idle cluster overnight is the usual way a sandbox budget
disappears.

---

## Verification performed

Everything below was executed, not assumed. What was *not* possible is stated
plainly at the end.

| Check | Result |
|---|---|
| `go test -race` | 13 test functions, 28 cases including subtests — all pass |
| `go vet`, `gofmt` | clean |
| `golangci-lint` (8 linters incl. `gosec`) | 0 issues |
| Coverage | 44.9% total; `run()` 100%, handlers 85–100% |
| `docker build` | succeeds; tests run inside the build |
| Container functional test | name parameter, IP fallback, XFF chain, CRLF stripping, unicode, length cap, 404, security headers — all confirmed against a running container |
| Graceful shutdown | drains and exits 0 in 0.21s |
| Image hardening | 2.5 MiB, 1 layer, UID 65532, no `/bin/sh` |
| `trivy image` | 0 vulnerabilities, 0 secrets |
| `terraform validate` | passes |
| `terraform fmt -check` | clean |
| `tflint` (+ AWS ruleset) | 0 issues |
| `trivy config` on Terraform | passes; 2 findings suppressed with written justification |
| `kubeconform -strict` (k8s 1.36) | 7/7 resources valid |
| `trivy config` on rendered manifests | passes |
| `actionlint` + `shellcheck` | 0 issues |
| ConfigMap hash rotation | confirmed: changing `HELLO_TAG` changes the hash, forcing a rollout |

### Deployed to a local Kubernetes cluster (kind)

Schema validation only proves a manifest is well-formed, not that it runs. The
workload was therefore deployed and exercised on a real Kubernetes control
plane — but a local one, **not on AWS**.

**Be clear about what this environment was:** a `kind` v0.33.0 cluster,
Kubernetes v1.37.0, running as four Docker containers on a laptop — one control
plane and three workers. The three workers were hand-labelled
`topology.kubernetes.io/zone=eu-central-1{a,b,c}`. Those labels are synthetic:
they give the scheduler's topology-spread constraint something real to act on,
but they are not AWS availability zones, and all four "nodes" share one machine.

So the Kubernetes control plane, scheduler, kubelet, kube-proxy and admission
chain were genuine, and the `k8s/base` kustomization was applied unmodified.
Nothing about AWS was exercised. The cluster was deleted afterwards.

| Check | Result |
|---|---|
| Admission under `restricted` Pod Security | all 7 objects accepted, no violations |
| Pods scheduled | 3/3 Running, **0 restarts** |
| Zone spread (hard constraint) | exactly one pod per labelled zone, across all three |
| Service load balancing | 60 requests distributed across all 3 backends |
| Greeting by `?name=` | 60/60 correct |
| `HELLO_TAG` propagation | 60/60 responses carried the tag |
| IP fallback, 404, `nosniff` headers | all correct through the Service |
| **Rolling update, measured under load** | **142 requests at 10/s across a full 3-pod replacement — 0 failures**, rollout completed in 8.1s |
| Zone spread after rollout | still one per zone |
| Runtime security context | `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, all capabilities dropped, UID 65532 — confirmed on the running pod |
| PodDisruptionBudget | admitted, 1 allowed disruption |
| ConfigMap-hash rollout trigger | changing `HELLO_TAG` produced a new hash and drove a rollout |

The zero-downtime result is the meaningful one: it exercises `maxUnavailable: 0`,
the readiness probes, the `preStop` sleep and the server's own drain together,
which is most of the chain the HA claim rests on — the ALB readiness gate is the
missing link, and it cannot be tested off AWS.

What this does **not** establish is AZ fault tolerance. Three containers on one
laptop with zone-shaped labels prove the scheduler honours the constraint; they
say nothing about surviving the loss of a real availability zone.

### What is still unverified

- **No `terraform apply` has run.** No AWS account was available, so no
  infrastructure has been created. Provider and module schemas were checked
  against the live registry and the configuration validates, but "validates" is
  a weaker claim than "applies cleanly".
- **The AWS-specific layer is untested by consequence:** the ALB and its
  Ingress annotations, ALB pod readiness gates, IRSA, the EKS addons, and the
  OIDC deploy role. The local cluster has no Load Balancer Controller, so the
  readiness-gate half of the zero-downtime chain was not exercised — only the
  Kubernetes half.
- **The HPA was admitted but never scaled**, since the local cluster has no
  `metrics-server`. On EKS it is installed as a managed addon.
- Version-sensitive choices (EKS 1.36, chart 3.5.0, provider v6/v3 syntax) were
  each confirmed against primary sources rather than recalled, but confirming a
  version is not the same as running it.
