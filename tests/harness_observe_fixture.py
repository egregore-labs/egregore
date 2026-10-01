"""Dependency-free Runtime fixture shared by Python and native harness tests."""

import os
from types import SimpleNamespace

from egregore_runtime import EvidenceItem, OrgContext, PolicyDecision, Permission


class FakeRuntime:
    def __init__(self):
        self.resolve_calls = []
        self.observe_calls = []
        self.open_calls = []
        self.decision = PolicyDecision(True, "actor_test", "org_test", Permission.READ, "epoch:test", scopes=("memory",))
        self.retriever = SimpleNamespace(describe_source=lambda path: SimpleNamespace(artifact_id="decision_test"), health=lambda: SimpleNamespace(source_revision="git:test", index_revision="index:test"))

    def policy_factory(self, actor):
        return SimpleNamespace(authorize_observe=lambda actor, request: self.decision)

    def authorize(self, actor, permission, artifact_ids=()):
        return self.decision

    def investigate(self, actor, request, **kwargs):
        from egregore_runtime.investigation import execute
        from egregore_runtime import harness_cli
        return execute(self,actor,request,root=harness_cli._invocation_root.get() or os.environ.get("EGREGORE_ROOT"),**kwargs)

    admin_gate = None

    def resolve_actor(self, *, session_id, harness):
        self.resolve_calls.append((session_id, harness))
        return SimpleNamespace(
            session_id=session_id,
            profile=SimpleNamespace(
                org_id="org_test",
                revision="profile:test",
                default_context_budget=2_000,
            ),
            actor=SimpleNamespace(
                actor_id="actor_test",
                display_name="Oz",
                aliases={"github.username": "oguzhan"},
            ),
        )

    def observe(self, actor, request, *, token_budget):
        self.observe_calls.append((actor, request, token_budget))
        original = OrgContext(
            schema_version='egregore-context/v1',
            context_id="ctx_test",
            org_id='org_test',actor_id='actor_test',task=request.task,
            policy_epoch=self.decision.policy_epoch,
            profile_revision="profile:test",
            source_revision=self.retriever.health().source_revision,
            freshness={
                "index_revision": self.retriever.health().index_revision,
                "lifecycle_revision": "lifecycle:test",
                "temporal_scope": "current",
            },
            evidence=(
                EvidenceItem(
                    artifact_id="decision_test",
                    canonical_path="memory/knowledge/decisions/runtime.md",
                    revision="git:test",
                    reason="retrieval rank 1",
                    content="Canonical Markdown is authoritative.",
                    token_count=8,
                ),
            ),
            action_permissions=frozenset({Permission.READ,Permission.DISCOVER}),
            token_budget=token_budget,tokens_used=8,
        )
        context = SimpleNamespace(**{name:getattr(original,name) for name in OrgContext.__dataclass_fields__})
        context.to_dict = lambda: OrgContext(**{name:getattr(context,name) for name in OrgContext.__dataclass_fields__}).to_dict()
        return context

    def open_source(self, actor, path):
        self.open_calls.append((actor, path))
        return "Full canonical source.\n"
