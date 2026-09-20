# 1. Use a fixed managed node group rather than Karpenter

- **Status:** Accepted
- **Date:** 2026-09-20

## Context

The cluster runs a managed node group with `min_size = 3`, `max_size = 6`,
`desired_size = 3`. Nothing drives the upper bound — there is no
cluster-autoscaler and no Karpenter, so `max_size` is a ceiling that is never
approached rather than a scaling target.

The HPA scales pods from 3 to 12. At the current request of 50m CPU, twelve
replicas ask for 600m against roughly 5790m allocatable across three
`t3.medium` nodes, so pod autoscaling cannot currently exhaust node capacity.
Node autoscaling is therefore not load-bearing at this workload size, and would
be the moment the request or replica count grew materially.

Karpenter is the current answer for node autoscaling on EKS, and adopting it
brings a well-documented disruption problem with it. During consolidation
Karpenter drains a node, and an evicted pod is terminated before a replacement
is scheduled elsewhere; for a single-replica workload that is plain downtime. A
PodDisruptionBudget is the usual guard, but `minAvailable: 1` on a single
replica blocks the eviction permanently, which deadlocks consolidation instead
of protecting availability. The trade is documented upstream in
[karpenter#1599][k1599], [karpenter#2600][k2600] and [kubernetes#90977][k90977].

That failure mode does not apply to this service as configured, and the reasons
are worth stating because they are properties that could silently regress:

- Three replicas, not one — `spec.replicas: 3` and HPA `minReplicas: 3`.
- The PDB is written as `maxUnavailable: 1`, **not** `minAvailable: 1`. It
  therefore always permits one eviction and cannot reach a state where it
  refuses every request.
- `unhealthyPodEvictionPolicy: AlwaysAllow` means an already-broken pod is
  evictable, so a failing pod cannot wedge a drain against the budget.

## Options considered

**Fixed managed node group (chosen).** No node autoscaling. Predictable cost
and no disruption controller to reason about. Leaves a real gap if the workload
grows past the node group.

**Cluster Autoscaler.** Scales the existing ASG. Node-shaped rather than
pod-shaped, so it bin-packs poorly and is slow to react. Largely superseded.

**Karpenter.** Provisions right-sized nodes directly and consolidates
aggressively. The correct production answer, and the one that requires the
disruption analysis above. The `terraform-aws-modules/eks//modules/karpenter`
submodule is already vendored by the EKS module this configuration uses, so the
Terraform cost is modest; the operational cost is the disruption behaviour,
which needs testing rather than configuration.

## Decision

Ship the fixed node group. Node autoscaling is not required at this workload
size and adding an aggressive disruption controller without the budget to test
its behaviour would trade a documented gap for an undocumented risk.

Record the disruption analysis here rather than discovering it during adoption,
and keep the PDB in the form that stays safe under consolidation.

## Consequences

- Sustained demand beyond what three nodes hold leaves pods `Pending` with no
  automatic remedy. Mitigation until Karpenter lands: raise `desired_size`.
- The zone-spread constraint is `DoNotSchedule`, so exhausting a single AZ's
  capacity blocks scheduling there rather than spilling into another zone. That
  is the intended trade — correctness of spread over best-effort placement.
- No spot capacity, so no interruption handling is required; adopting spot
  would additionally need `aws-node-termination-handler` or Karpenter's own
  interruption queue, and a node-level termination budget that fits inside the
  40s `terminationGracePeriodSeconds` this deployment already uses.
- For any future single-replica workload in this cluster, the eviction problem
  is real and the PDB is not the answer. A surge-before-evict helper such as
  [evict-to-rollout][etr] is.

## Code location

- `terraform/eks.tf` — `eks_managed_node_groups.default`, the scaling config.
- `k8s/base/pdb.yaml` — `maxUnavailable: 1`, `unhealthyPodEvictionPolicy`.
- `k8s/base/hpa.yaml` — `minReplicas: 3`.

## Guarding test

`k8s/base/pdb.yaml` is asserted by `kubeconform` in CI, which is schema-level
only and does **not** prove the disruption property. The claim that this
configuration survives a drain is currently **unverified**: it needs a
`kubectl drain` against a live node with continuous request sampling, which is
listed in the README TODO. Until that exists, treat this ADR's safety argument
as reasoned rather than demonstrated.

## Revisit when

Any one of:

- A pod is observed `Pending` with reason `Insufficient cpu` or
  `Insufficient memory`.
- `desired_size` is raised above 4, i.e. manual scaling has become routine.
- A workload with `replicas: 1` is added to this cluster.
- Spot capacity is adopted for the node group.

[k1599]: https://github.com/kubernetes-sigs/karpenter/issues/1599
[k2600]: https://github.com/kubernetes-sigs/karpenter/issues/2600
[k90977]: https://github.com/kubernetes/kubernetes/issues/90977
[etr]: https://github.com/HivemindTechnologies/evict-to-rollout
