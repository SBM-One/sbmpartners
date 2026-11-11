"""Shared settings for every agent: the AI client, model choice, and cost tracking."""
from __future__ import annotations

import os
from dataclasses import dataclass, field

import anthropic

# One place to change models. Opus is the most capable; it's used for work that
# needs judgment (research, grading). Cheaper models can be swapped in per agent later.
MODEL = os.environ.get("SBM_MODEL", "claude-opus-5-5")

# List prices in US dollars (per million tokens, and per web search). Used only to
# report what a run cost; the real bill is on console.anthropic.com.
PRICES = {
    "claude-opus-5-5": (4.00, 20.00),
    "claude-sonnet-5-5": (2.00, 10.00),
    "claude-haiku-5-5": (0.10, 0.50),
}
WEB_SEARCH_PRICE = 10.00 / 1000

# On a rare safety decline the API re-runs the request on a fallback model.
FALLBACK_BETA = "server-side-fallback-2026-07-01"


def client() -> anthropic.Anthropic:
    if not os.environ.get("ANTHROPIC_API_KEY"):
        raise SystemExit(
            "ANTHROPIC_API_KEY is not set. Put it in your .env file (see .env.example) "
            "and run: set -a; source .env; set +a"
        )
    return anthropic.Anthropic(max_retries=4)


@dataclass
class Usage:
    """Adds up tokens and web searches across every call in one run."""

    input_tokens: int = 0
    output_tokens: int = 0
    web_searches: int = 0
    by_model: dict = field(default_factory=dict)

    def add(self, message) -> None:
        u = message.usage
        inp = (u.input_tokens or 0) + (getattr(u, "cache_creation_input_tokens", 0) or 0) + (
            getattr(u, "cache_read_input_tokens", 0) or 0
        )
        out = u.output_tokens or 0
        self.input_tokens += inp
        self.output_tokens += out
        stu = getattr(u, "server_tool_use", None)
        if stu is not None:
            self.web_searches += getattr(stu, "web_search_requests", 0) or 0
        m = self.by_model.setdefault(message.model, [0, 0])
        m[0] += inp
        m[1] += out

    @property
    def cost_usd(self) -> float:
        total = self.web_searches * WEB_SEARCH_PRICE
        for model, (inp, out) in self.by_model.items():
            pin, pout = PRICES.get(model, PRICES["claude-opus-5-5"])
            total += inp / 1e6 * pin + out / 1e6 * pout
        return round(total, 2)
