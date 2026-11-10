"""The short list of OpenRouter models offered in the UI (all support tool calling). Any other OpenRouter model id
can be typed in Settings."""

from dataclasses import asdict, dataclass


@dataclass(frozen=True)
class Model:
    id: str
    label: str
    vendor: str
    note: str


MODELS = (
    Model("anthropic/claude-sonnet-5.5", "Claude Sonnet 5.5", "Anthropic", "Recommended: strong analysis, fair price"),
    Model("anthropic/claude-opus-5.5", "Claude Opus 5.5", "Anthropic", "Deepest reasoning for hard questions"),
    Model("anthropic/claude-fable-5.2", "Claude Fable 5.2", "Anthropic", "Most capable, most expensive"),
    Model("anthropic/claude-haiku-5.5", "Claude Haiku 5.5", "Anthropic", "Fast and cheap for quick lookups"),
    Model("openai/gpt-6.1-sol", "GPT-6.1 Sol", "OpenAI", "OpenAI's balanced model"),
    Model("google/gemini-4-argon", "Gemini 4 Argon", "Google", "Google's flagship"),
    Model("deepseek/deepseek-v4.1-flash", "DeepSeek V4.1 Flash", "DeepSeek", "Very low cost"),
)
DEFAULT_MODEL = MODELS[0].id


def as_list() -> list[dict[str, str]]:
    return [asdict(m) for m in MODELS]


def label(model_id: str) -> str:
    return next((m.label for m in MODELS if m.id == model_id), model_id)
