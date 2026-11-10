"""The short list of OpenRouter models offered in the UI: mostly low-cost Chinese models, all with tool calling
(checked against OpenRouter's model list, Nov 2026; prices in USD per million input / output tokens). Any other
OpenRouter model id can be typed in Settings."""

from dataclasses import asdict, dataclass


@dataclass(frozen=True)
class Model:
    id: str
    label: str
    vendor: str
    note: str


MODELS = (
    Model(
        "deepseek/deepseek-v4.1-flash",
        "DeepSeek V4.1 Flash",
        "DeepSeek",
        "Recommended: newest DeepSeek, almost free ($0.006 / $0.50)",
    ),
    Model(
        "deepseek/deepseek-v4-pro-0813",
        "DeepSeek V4 Pro",
        "DeepSeek",
        "Stronger reasoning for hard questions ($0.11 / $4.44)",
    ),
    Model("qwen/qwen3.8-flash", "Qwen 3.8 Flash", "Alibaba", "Fast and cheap ($0.15 / $0.47)"),
    Model("z-ai/glm-5.3", "GLM 5.3", "Zhipu", "Zhipu's full model, cheap input ($0.07 / $1.40)"),
    Model("minimax/minimax-m3.1-flash", "MiniMax M3.1 Flash", "MiniMax", "Newest MiniMax, low cost ($0.15 / $0.60)"),
    Model("xiaomi/mimo-v2.6-pro", "MiMo V2.6 Pro", "Xiaomi", "Xiaomi's pro tier ($0.44 / $0.87)"),
    Model("anthropic/claude-haiku-5.5", "Claude Haiku 5.5", "Anthropic", "Reliable and cheap ($0.10 / $0.50)"),
    Model(
        "anthropic/claude-sonnet-5.5", "Claude Sonnet 5.5", "Anthropic", "Best answers when quality matters ($2 / $10)"
    ),
)
DEFAULT_MODEL = MODELS[0].id


def as_list() -> list[dict[str, str]]:
    return [asdict(m) for m in MODELS]


def label(model_id: str) -> str:
    return next((m.label for m in MODELS if m.id == model_id), model_id)
