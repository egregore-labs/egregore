class EgregoreRuntimeError(RuntimeError):
    """Base error for domain-level runtime failures."""


class AuthorizationDenied(EgregoreRuntimeError):
    """The actor is not authorized to observe or perform an action."""


class ContextBudgetError(EgregoreRuntimeError):
    """The requested context budget cannot hold a valid manifest."""
