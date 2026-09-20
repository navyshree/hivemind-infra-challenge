# Architecture decision records

Decisions whose reasoning is not recoverable from the code. Anything that is
obvious from reading the resource stays a comment; anything where a future
reader would reasonably ask "why not the other thing?" belongs here.

Format is Nygard-shaped: Status, Date, Context, Options considered, Decision,
Consequences — plus the code location, the test that guards the decision, and
an observable trigger for revisiting it. Where no guarding test exists that is
stated explicitly, because an unverified claim recorded as verified is worse
than one recorded as open.

| # | Decision | Status | Guarded |
|---|---|---|---|
| [0001](0001-fixed-node-group-over-karpenter.md) | Fixed managed node group rather than Karpenter | Accepted | No — drain behaviour untested, see TODO |

Decisions still living as code comments rather than ADRs, in rough order of how
much a reader would want the reasoning: EKS 1.36 over 1.35 (standard-support
runway vs extended-support billing); no CPU limit on the container; ALB
controller chart pinned to 3.5.0; `authentication_mode = "API"`; buildx
attestations disabled so ECR scanning can read the image; HTTP-only ingress.
Each is commented at its definition — the argument for promoting them is that a
comment cannot be indexed, and a decision nobody can find is prose.
