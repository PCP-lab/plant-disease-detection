"""Management tips from open-source LLMs, grounded in the photo, the scan result, local weather and a curated
treatment list.

Two steps, both through an OpenAI-compatible chat API (Ollama by default):
1. describe_photo: a vision model (LLM_VISION_MODEL) looks at the leaf photo and reports the visible symptoms.
2. get_advice: the text model (LLM_MODEL) writes the tips from those observations + coverage/severity + weather.

The text model may only recommend products from DISEASE_GUIDE: treatments it returns that match no guide entry
are dropped, and FRAC codes come from the guide, not the model, so a hallucinated product or resistance group
never reaches the user.
"""

import base64
import io
import json
import logging
import re

import httpx
from fastapi import HTTPException, status
from PIL import Image

from app.config import settings

log = logging.getLogger("uvicorn.error")

DISCLAIMER = (
    "AI-generated guidance, not a substitute for a local agronomist or extension officer. Check that any product is "
    "registered for your crop in your country, and follow its label for rate, PPE, re-entry and pre-harvest intervals."
)

# Treatment options per disease. frac = FRAC resistance-management code (rotate codes between sprays).
DISEASE_GUIDE: dict[str, dict] = {
    "powdery_mildew": {
        "label": "Powdery mildew",
        "cultural": [
            "Remove and destroy badly infected leaves",
            "Improve air flow: prune, stake, widen spacing",
            "Avoid excess nitrogen (soft growth is susceptible)",
            "Water at the base in the morning; mildew needs humidity, not wet leaves",
            "Plant resistant varieties next season",
        ],
        "products": [
            {"name": "Sulfur (wettable)", "type": "organic", "frac": "M2", "keys": ["sulfur", "sulphur"],
             "note": "Protectant; don't apply above 32 °C or within 2 weeks of an oil spray"},
            {"name": "Potassium bicarbonate", "type": "organic", "frac": "NC", "keys": ["bicarbonate"],
             "note": "Contact eradicant; needs thorough coverage"},
            {"name": "Neem oil / horticultural oil", "type": "organic", "frac": "NC",
             "keys": ["neem", "horticultural oil", "paraffinic oil", "mineral oil"],
             "note": "Not in heat above 32 °C or with sulfur"},
            {"name": "Bacillus subtilis / amyloliquefaciens", "type": "organic", "frac": "BM02", "keys": ["bacillus"],
             "note": "Biological; preventive, best at low pressure"},
            {"name": "Myclobutanil", "type": "conventional", "frac": "3", "keys": ["myclobutanil"],
             "note": "Systemic DMI"},
            {"name": "Tebuconazole", "type": "conventional", "frac": "3", "keys": ["tebuconazole"],
             "note": "Systemic DMI"},
            {"name": "Azoxystrobin", "type": "conventional", "frac": "11", "keys": ["azoxystrobin"],
             "note": "QoI, high resistance risk: max 2 sprays in a row"},
            {"name": "Trifloxystrobin", "type": "conventional", "frac": "11", "keys": ["trifloxystrobin"],
             "note": "QoI, high resistance risk"},
            {"name": "Boscalid", "type": "conventional", "frac": "7", "keys": ["boscalid"], "note": "SDHI"},
        ],
    },
    "leaf_spot": {
        "label": "Leaf spot (fungal or bacterial)",
        "cultural": [
            "Remove and destroy spotted leaves and fallen debris",
            "Avoid overhead irrigation; water at the base early in the day",
            "Don't work among plants while they are wet",
            "Mulch to stop soil splashing onto lower leaves",
            "Rotate crops and use clean seed / transplants",
        ],
        "products": [
            {"name": "Copper (hydroxide / oxychloride)", "type": "organic", "frac": "M1", "keys": ["copper"],
             "note": "Protectant; the main option if the spot is bacterial"},
            {"name": "Bacillus subtilis / amyloliquefaciens", "type": "organic", "frac": "BM02", "keys": ["bacillus"],
             "note": "Biological; preventive"},
            {"name": "Chlorothalonil", "type": "conventional", "frac": "M5", "keys": ["chlorothalonil"],
             "note": "Multi-site protectant; banned in the EU"},
            {"name": "Mancozeb", "type": "conventional", "frac": "M3", "keys": ["mancozeb"],
             "note": "Multi-site protectant; banned in the EU"},
            {"name": "Azoxystrobin", "type": "conventional", "frac": "11", "keys": ["azoxystrobin"],
             "note": "QoI, high resistance risk"},
            {"name": "Difenoconazole", "type": "conventional", "frac": "3", "keys": ["difenoconazole"],
             "note": "Systemic DMI"},
            {"name": "Tebuconazole", "type": "conventional", "frac": "3", "keys": ["tebuconazole"],
             "note": "Systemic DMI"},
        ],
    },
}

SYSTEM_PROMPT = """You are a practical plant-health advisor (agronomist) helping a grower act on a leaf scan.
You are given: the scan result (disease coverage % and severity per disease, measured by a segmentation model),
what a vision model saw in the leaf photo, current local weather with pre-computed spray conditions and disease
pressure, and the ONLY treatment products you may recommend.

Rules:
- The scan percentages are the measurement. Use the photo observations to confirm them and to describe the symptoms
  in the summary. If the photo shows something else (pests, nutrient deficiency, sunscald), mention it with cultural
  advice only. If the photo clearly contradicts the scan, or is blurry/dark, say the result should be re-checked.
- Recommend chemical/biological products ONLY from the provided list, using their names as given. Never invent products, brands or rates.
- Match intensity to severity: none -> prevention only; mild -> cultural + organic first; moderate/severe -> add conventional options.
- Recommend rotating FRAC groups; never two sprays of the same group in a row.
- Respect the weather: no spraying if rain is expected before the product dries, in wind, or outside the spray window. Name the spray window if there is one; if not, say to wait.
- Use the disease-pressure levels to say whether the weather favours spread. Use week_outlook to name the days
  when risk peaks or rises, and to plan protectant sprays on good spray days just before high-risk days.
- Leaf spot may be bacterial; if so, copper is the option and fungicides will not help.
- Be concise and practical, plain language for a farmer. Up to 5 actions, up to 6 treatments, up to 4 prevention tips.

Reply with ONLY a JSON object of this shape:
{"summary": "2-3 sentences: what was found and what the weather means for it",
 "urgency": "low" | "medium" | "high",
 "actions": ["step 1, most urgent first", "..."],
 "treatments": [{"name": "product from the list, or a cultural practice", "type": "cultural" | "organic" | "conventional", "how": "when/how to use it, one sentence"}],
 "spray_timing": "one sentence on when to spray (or not) given the weather",
 "prevention": ["tip", "..."]}"""


def _diseases_present(scan: dict) -> list[str]:
    leaves = scan.get("leaves") or ([scan["primary"]] if scan.get("primary") else [])
    return [d for d in DISEASE_GUIDE if any(leaf["severity"].get(d, "none") != "none" for leaf in leaves)]


def _scan_report(scan: dict) -> dict:
    primary = scan["primary"]
    leaves = scan.get("leaves") or [primary]
    report = {
        "leaves_in_photo": len(leaves),
        "largest_leaf": {
            "powdery_mildew_pct": primary["powdery_mildew_pct"],
            "leaf_spot_pct": primary["leaf_spot_pct"],
            "healthy_pct": primary["healthy_pct"],
            "severity": primary["severity"],
        },
    }
    if len(leaves) > 1:
        report["all_leaves"] = {
            d: {
                "leaves_affected": sum(1 for leaf in leaves if leaf[f"{d}_pct"] > 0),
                "max_pct": max(leaf[f"{d}_pct"] for leaf in leaves),
            }
            for d in DISEASE_GUIDE
        }
    return report


def _week_outlook(outlook: dict) -> dict:
    """Compact 7-day risk for the prompt: one line per day plus the trend per disease."""
    return {
        "days": [
            f"{d['label']}: mildew {d['powdery_mildew_level']}, leaf spot {d['leaf_spot_level']}, "
            f"rain {d['rain_mm']} mm, {'good' if d['spray_ok'] else 'no'} spray window"
            for d in outlook["days"]
        ],
        "trends": outlook["trends"],
    }


def build_messages(
    scan: dict, conditions: dict | None, crop: str | None, photo: dict | None = None, outlook: dict | None = None
) -> list[dict]:
    diseases = _diseases_present(scan) or list(DISEASE_GUIDE)  # healthy: prevention for both
    allowed = {
        DISEASE_GUIDE[d]["label"]: {
            "cultural": DISEASE_GUIDE[d]["cultural"],
            "products": [
                {"name": p["name"], "type": p["type"], "frac": p["frac"], "note": p["note"]}
                for p in DISEASE_GUIDE[d]["products"]
            ],
        }
        for d in diseases
    }
    guess = (photo or {}).get("crop_guess", "")
    if not crop and guess and guess.lower() not in ("unknown", "none", ""):
        crop = f"probably {guess} (guessed from the photo, not confirmed)"
    context = {
        "crop": crop or "unknown (give general advice)",
        "scan": _scan_report(scan),
        "photo_observations": photo or "no photo available (rely on the scan numbers)",
        "weather": conditions or "unavailable (say that timing advice is general)",
        "week_outlook": _week_outlook(outlook) if outlook else "unavailable",
        "allowed_treatments": allowed,
    }
    return [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": json.dumps(context, indent=1, ensure_ascii=False)},
    ]


def _match_product(name: str, diseases: list[str]) -> dict | None:
    lower = name.lower()
    for d in diseases:
        for p in DISEASE_GUIDE[d]["products"]:
            if any(k in lower for k in p["keys"]):
                return p
    return None


def _str_list(value, limit: int) -> list[str]:
    if not isinstance(value, list):
        return []
    return [str(v).strip() for v in value if str(v).strip()][:limit]


def _fallback_urgency(scan: dict) -> str:
    worst = max(
        (s for leaf in scan.get("leaves") or [scan["primary"]] for s in leaf["severity"].values()),
        key=["none", "mild", "moderate", "severe"].index,
        default="none",
    )
    return {"none": "low", "mild": "medium"}.get(worst, "high")


def parse_reply(text: str, scan: dict) -> dict:
    """LLM text → Advice fields (without weather/model/disclaimer). Raises ValueError if it isn't usable."""
    match = re.search(r"\{.*\}", text, re.DOTALL)  # tolerate ```json fences or chatter around the object
    if not match:
        raise ValueError("no JSON object in reply")
    data = json.loads(match.group(0))
    if not isinstance(data, dict) or not str(data.get("summary", "")).strip():
        raise ValueError("reply has no summary")

    diseases = _diseases_present(scan) or list(DISEASE_GUIDE)
    treatments, seen = [], set()
    for t in data.get("treatments") or []:
        if not isinstance(t, dict) or not str(t.get("name", "")).strip():
            continue
        name, kind, how = str(t["name"]).strip(), str(t.get("type", "")).lower().strip(), str(t.get("how", "")).strip()
        product = _match_product(name, diseases)
        if product:  # grounded: canonical name, type and FRAC code from the guide
            if product["name"] in seen:
                continue
            seen.add(product["name"])
            treatments.append({"name": product["name"], "type": product["type"], "how": how, "frac_group": product["frac"]})
        elif kind == "cultural":
            treatments.append({"name": name, "type": "cultural", "how": how, "frac_group": None})
        else:
            log.info("Dropped ungrounded treatment from LLM: %r", name)

    urgency = str(data.get("urgency", "")).lower()
    return {
        "summary": str(data["summary"]).strip(),
        "urgency": urgency if urgency in ("low", "medium", "high") else _fallback_urgency(scan),
        "actions": _str_list(data.get("actions"), 6),
        "treatments": treatments[:8],
        "spray_timing": str(data.get("spray_timing") or "").strip(),
        "prevention": _str_list(data.get("prevention"), 5),
    }


class LLMError(Exception):
    """A chat call failed. kind: "unreachable", "model_missing", "error" or "bad_reply"."""

    def __init__(self, kind: str, message: str):
        super().__init__(message)
        self.kind = kind


def _chat(model: str, messages: list[dict]) -> str:
    """One JSON-mode chat completion → the reply text. Raises LLMError."""
    headers = {"Authorization": f"Bearer {settings.llm_api_key}"} if settings.llm_api_key else {}
    body = {"model": model, "messages": messages, "temperature": 0.2, "response_format": {"type": "json_object"}}
    url = f"{settings.llm_base_url.rstrip('/')}/chat/completions"
    try:
        res = httpx.post(url, json=body, headers=headers, timeout=settings.llm_timeout_s)
    except (httpx.ConnectError, httpx.TimeoutException) as e:
        log.warning("LLM unreachable at %s: %s", url, e)
        raise LLMError("unreachable", str(e)) from e
    except httpx.HTTPError as e:
        log.warning("LLM request to %s failed: %s", url, e)
        raise LLMError("error", type(e).__name__) from e
    if res.status_code == 404:
        # Ollama (and most OpenAI-compatible servers) answer 404 for a model they don't have.
        log.warning("LLM model %r not found at %s: %s", model, url, res.text[:500])
        raise LLMError("model_missing", f"model {model!r} not found")
    if res.status_code >= 400:
        log.warning("LLM %r error %s: %s", model, res.status_code, res.text[:500])
        raise LLMError("error", str(res.status_code))
    try:
        return res.json()["choices"][0]["message"]["content"]
    except (ValueError, KeyError, IndexError, TypeError) as e:
        raise LLMError("bad_reply", res.text[:500]) from e


def _missing_model_message(model: str, setting: str) -> str:
    return (
        f"AI model '{model}' is not installed on the advice server "
        f"(for Ollama: ollama pull {model}), or {setting} in backend/.env is wrong."
    )


VISION_PROMPT = """This is a photo of a plant leaf taken for a disease scan. Describe only what you can actually see.
Reply with ONLY a JSON object:
{"crop_guess": "plant species if recognisable from the leaf, else unknown",
 "symptoms": "2-3 sentences: colour, shape, size and position of any spots or lesions, white powdery growth, yellowing, browning, curling, holes",
 "other_issues": "visible problems that are not powdery mildew or leaf spot (insects, mites, webbing, nutrient deficiency, sunscald, physical damage), or none",
 "image_quality": "good" | "blurry" | "too dark" | "leaf too small"}"""


def _photo_data_url(img: Image.Image) -> str:
    small = img.copy()
    small.thumbnail((settings.llm_vision_image_side, settings.llm_vision_image_side), Image.Resampling.LANCZOS)
    buf = io.BytesIO()
    small.convert("RGB").save(buf, format="JPEG", quality=85)
    return "data:image/jpeg;base64," + base64.b64encode(buf.getvalue()).decode()


def describe_photo(img: Image.Image) -> tuple[dict | None, str | None]:
    """Vision model's observations of the leaf photo → (observations, None), or (None, why it was skipped).

    Never raises: the tips can still be written from the scan results and weather without the photo.
    """
    model = settings.llm_vision_model
    if not model:
        return None, "Photo analysis is turned off (LLM_VISION_MODEL is empty)."
    messages = [
        {
            "role": "user",
            "content": [
                {"type": "text", "text": VISION_PROMPT},
                {"type": "image_url", "image_url": {"url": _photo_data_url(img)}},
            ],
        }
    ]
    try:
        text = _chat(model, messages)
        match = re.search(r"\{.*\}", text, re.DOTALL)
        data = json.loads(match.group(0)) if match else None
    except LLMError as e:
        log.warning("Photo analysis with %r failed: %s", model, e)
        note = {
            "model_missing": f"Photo not analysed: vision model '{model}' is not installed (ollama pull {model}).",
            "unreachable": "Photo not analysed: the vision model could not be reached.",
        }.get(e.kind, "Photo not analysed: the vision model returned an error.")
        return None, note
    except ValueError:
        data = None
    if not isinstance(data, dict) or not str(data.get("symptoms", "")).strip():
        log.warning("Unusable vision reply from %r: %r", model, (text or "")[:500])
        return None, "Photo not analysed: the vision model gave an unusable answer."
    return {k: str(data.get(k, "")).strip() for k in ("crop_guess", "symptoms", "other_issues", "image_quality")}, None


def photo_summary(photo: dict) -> str:
    """One readable line for the app: the symptoms, plus other issues and poor image quality when present."""
    parts = [photo["symptoms"]]
    if photo.get("other_issues") and photo["other_issues"].lower().rstrip(".") not in ("none", "no", "n/a"):
        parts.append(f"Also seen: {photo['other_issues']}")
    if photo.get("image_quality") and photo["image_quality"].lower() != "good":
        parts.append(f"Image quality: {photo['image_quality']}.")
    return " ".join(parts)


def get_advice(
    scan: dict, conditions: dict | None, crop: str | None, photo: dict | None = None, outlook: dict | None = None
) -> dict:
    """Calls the text LLM. 503 if it can't be reached, 502 if it errors or replies with something unusable."""
    try:
        text = _chat(settings.llm_model, build_messages(scan, conditions, crop, photo, outlook))
        return parse_reply(text, scan)
    except LLMError as e:
        if e.kind == "unreachable":
            raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "Advice service unavailable. Try again later.") from e
        if e.kind == "model_missing":
            raise HTTPException(status.HTTP_502_BAD_GATEWAY, _missing_model_message(settings.llm_model, "LLM_MODEL")) from e
        if e.kind == "error":
            raise HTTPException(status.HTTP_502_BAD_GATEWAY, f"Advice service error ({e})") from e
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, "The AI gave an unusable answer. Please try again.") from e
    except (ValueError, KeyError, TypeError) as e:
        log.warning("Unusable LLM reply: %s", e)
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, "The AI gave an unusable answer. Please try again.") from e
