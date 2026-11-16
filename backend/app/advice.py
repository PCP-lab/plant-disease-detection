"""Management tips from open-source LLMs, grounded in the photo, the scan result, local weather and a curated
treatment list.

Two steps, both through an OpenAI-compatible chat API (Ollama by default):
1. describe_photo: a vision model (LLM_VISION_MODEL) checks the photo for what the scan can't see: other problems
   (insects, nutrient deficiency, sunscald) and image quality. The scan alone decides the diseases.
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

# What the app shows under each product. Written here, not by the LLM: in testing the LLM invented spray rates
# ("1 L/ha, 1:1000") despite being told not to. No rates or doses: the product label decides those.
PRODUCT_HOW = {
    "Sulfur (wettable)": "Protective spray. Not above 32 °C or within 2 weeks of an oil spray.",
    "Potassium bicarbonate": "Kills mildew on contact. Cover both sides of the leaves.",
    "Neem oil / horticultural oil": "Cover the leaves well. Not in heat above 32 °C or with sulfur.",
    "Bacillus subtilis / amyloliquefaciens": "Biological. Works best early, before the disease spreads.",
    "Myclobutanil": "Follow-up if it keeps spreading. At most 2 sprays in a row.",
    "Tebuconazole": "Follow-up if it keeps spreading. At most 2 sprays in a row.",
    "Azoxystrobin": "Follow-up if it keeps spreading. High resistance risk: at most 2 in a row.",
    "Trifloxystrobin": "Follow-up if it keeps spreading. High resistance risk: at most 2 in a row.",
    "Boscalid": "Follow-up if it keeps spreading. Alternate with a different group.",
    "Copper (hydroxide / oxychloride)": "Protective spray. The main option if the spots are bacterial.",
    "Chlorothalonil": "Protective follow-up if it keeps spreading. Not allowed in the EU.",
    "Mancozeb": "Protective follow-up if it keeps spreading. Not allowed in the EU.",
    "Difenoconazole": "Follow-up if it keeps spreading. At most 2 sprays in a row.",
}

SYSTEM_PROMPT = """You are a practical plant-health advisor (agronomist) helping a grower act on a leaf scan.
You are given: the scan result (disease coverage % and severity per disease, measured by a segmentation model),
a photo check (other problems and image quality), current local weather with pre-computed spray conditions and
disease pressure, and the ONLY treatment products you may recommend.

Rules:
- The scan decides which diseases are present and how severe they are. Never contradict it and never tell the
  grower to re-check it.
- The photo check only adds what the scan cannot see: other problems (insects, mites, chewed holes, sunscald): at
  most one action for them, after the disease steps; and image quality: if blurry or too dark, one action says to
  retake the photo.
- Recommend chemical/biological products ONLY from the provided list, using their names as given. Never invent
  products or brands, and NEVER give rates, doses, dilutions or volumes: the product label decides those.
- One product per spray. Choose products for the disease with the larger coverage. Give the organic product first;
  the conventional one is a follow-up only if the disease keeps spreading after 7-10 days.
- Match intensity to severity: none -> prevention only; mild -> cultural + organic first; moderate/severe -> add conventional options.
- Recommend rotating FRAC groups; never two sprays of the same group in a row.
- Respect the weather: no spraying if rain is expected before the product dries, in wind, or outside the spray window. Name the spray window if there is one; if not, say to wait.
- Use the disease-pressure levels to say whether the weather favours spread. Use week_outlook to name the days
  when risk peaks or rises, and to plan protectant sprays on good spray days just before high-risk days.
- Leaf spot may be bacterial; if so, copper is the option and fungicides will not help.
- BE BRIEF. The grower reads this on a phone. Plain words, no repetition between fields, no filler.
  * summary: ONE sentence, at most 15 words: what was found and whether the weather favours spread.
  * actions: at most 3, most urgent first, each at most 12 words, each a concrete thing to do (start with a verb).
    Include the main cultural step and the spray step. Do NOT repeat the spray window's day or time (the app shows
    it): write "in the spray window", or "wait for a dry, calm day" if there is no window.
  * treatments: at most 2 products from the list: the best organic/low-toxicity one, and ONE conventional one only
    if severity is moderate or severe. Every product named in the actions must be in treatments.

Reply with ONLY a JSON object of this shape:
{"summary": "one short sentence",
 "actions": ["short step", "short step", "short step"],
 "treatments": [{"name": "product from the list", "type": "organic" | "conventional"}]}"""


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
        "photo_check": ({k: photo.get(k, "") for k in ("other_issues", "image_quality")} if photo
                        else "no photo check available"),
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


# Hard limits on what reaches the phone, whatever the model writes (it doesn't always follow length instructions).
MAX_ACTIONS, MAX_TREATMENTS = 3, 2
SUMMARY_WORDS, ACTION_WORDS = 20, 14


def brief(text, max_words: int) -> str:
    """First sentence only, cut to max_words (with an ellipsis if cut)."""
    text = " ".join(str(text or "").split())
    sentence = re.split(r"(?<=[.!?])\s+", text, maxsplit=1)[0]
    words = sentence.split()
    return sentence if len(words) <= max_words else " ".join(words[:max_words]).rstrip(",;:") + "…"


def _step(text, max_words: int) -> str:
    """A list item as shown in the app: brief, capitalised, no trailing full stop (they're shown as a numbered list)."""
    s = brief(text, max_words)
    s = s[:-1] if s.endswith(".") else s
    return s[:1].upper() + s[1:]


def _str_list(value, limit: int, max_words: int) -> list[str]:
    if not isinstance(value, list):
        return []
    return [_step(v, max_words) for v in value if str(v).strip()][:limit]


def spray_timing_text(conditions: dict | None) -> str:
    """From the computed spray window (weather.derive_conditions), not the LLM: exact and short. '' without weather."""
    if not conditions:
        return ""
    window = conditions.get("spray_window")
    return f"Spray window: {window}" if window else "No good spray window in the next 48 h"


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
    treatments, seen_types = [], set()
    for t in data.get("treatments") or []:
        if not isinstance(t, dict) or not str(t.get("name", "")).strip():
            continue
        product = _match_product(str(t["name"]).strip(), diseases)
        if not product:  # invented product, or a cultural step (those belong in the actions)
            log.info("Dropped treatment from LLM: %r", t["name"])
            continue
        if product["type"] in seen_types:  # at most one organic + one conventional
            continue
        seen_types.add(product["type"])
        # grounded: canonical name, type, FRAC code and the "how" text all come from our list, not the LLM
        treatments.append({"name": product["name"], "type": product["type"],
                           "how": PRODUCT_HOW.get(product["name"], product["note"]), "frac_group": product["frac"]})

    # A conventional fungicide is only ever the follow-up, never sprayed alongside the organic one (the LLM still
    # wrote "Apply Myclobutanil in the spray window" next to "Apply Sulfur…" despite the rule).
    actions = []
    for a in _str_list(data.get("actions"), MAX_ACTIONS, ACTION_WORDS):
        product = _match_product(a, diseases)
        if product and product["type"] == "conventional":
            a = f"If it still spreads in 7–10 days, spray {product['name']}"
        actions.append(a)

    return {
        "summary": brief(data["summary"], SUMMARY_WORDS),
        # From the scan, not the LLM: in testing it rated a mild leaf "high" and a moderate one "medium".
        "urgency": _fallback_urgency(scan),
        "actions": actions,
        "treatments": treatments[:MAX_TREATMENTS],
        "spray_timing": "",  # filled from the weather by the route (spray_timing_text)
        "prevention": [],  # folded into the actions; kept so older app builds still parse the response
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


# The photo check covers only what the segmentation model can't: the crop, other problems, and image quality. It
# no longer describes mildew/spots: in testing the 7B vision model said "no white powdery growth" on leaves the scan
# measured at up to 21 % mildew, and the contradiction confused the advice.
VISION_PROMPT = """This is a photo of a plant leaf taken for a disease scan. Another model already measures powdery
mildew and leaf spot, so do not describe those. Report only what you can clearly see.
Reply with ONLY a JSON object:
{"crop_guess": "plant species if recognisable from the leaf, else unknown",
 "other_issues": "ONLY if clearly visible: insects, mites, webbing, chewed holes, or sunscald (bleached, papery patches). Otherwise exactly: none",
 "image_quality": "good" | "blurry" | "too dark" | "leaf too small"}"""
# Nutrient deficiency is left out on purpose: the 7B model reported it on half the test photos (mildew and spot
# damage look like yellowing), which turned into fertiliser advice on a disease scan.


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
    if not isinstance(data, dict) or not any(str(data.get(k, "")).strip() for k in ("other_issues", "image_quality")):
        log.warning("Unusable vision reply from %r: %r", model, (text or "")[:500])
        return None, "Photo not analysed: the vision model gave an unusable answer."
    photo = {k: str(data.get(k, "")).strip() for k in ("crop_guess", "other_issues", "image_quality")}
    # Disease is the scan's job; the vision model still sometimes reports it ("powdery mildew") despite the prompt.
    if any(w in photo["other_issues"].lower() for w in ("mildew", "leaf spot", "spots", "powder", "fung", "disease")):
        photo["other_issues"] = "none"
    return photo, None


def photo_summary(photo: dict) -> str:
    """One line for the app: other problems seen, and a retake hint for a poor photo; never a disease verdict."""
    parts = []
    issues = photo.get("other_issues", "").strip().rstrip(".")
    if issues and issues.lower() not in ("none", "no", "n/a", "nothing"):
        parts.append(f"Also seen: {issues}.")
    quality = photo.get("image_quality", "").strip().lower().rstrip(".")
    if quality and quality != "good":
        parts.append(f"Image quality: {quality}. Retake for a more reliable result.")
    return " ".join(parts) or "Photo checked: no insects or other problems seen."


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
