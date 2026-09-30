#!/usr/bin/env python3
from __future__ import annotations

import json
import html
import os
import random
import re
import sys
import time
import traceback
from threading import Event, Lock, Thread


MODEL_PATH = os.environ.get(
    "TRANSLATE_TEXT_MODEL",
    "/Users/jingyuan/.lmstudio/models/mlx-community/translategemma-12b-it-4bit",
)
START_BACKEND = os.environ.get("TRANSLATE_TEXT_BACKEND", "gemma").strip().lower()
GOOGLE_FALLBACK_ORDER = os.environ.get(
    "TRANSLATE_TEXT_GOOGLE_FALLBACK_ORDER",
    "google_mobile,google_rpc,google_gtx",
)
CLOUD_FALLBACK_ORDER = os.environ.get("TRANSLATE_TEXT_CLOUD_FALLBACK_ORDER", "Google → Bing → DeepL")

LANG_MAP = {
    "简体中文": "zh",
    "繁體中文": "zh-Hant",
    "English": "en",
    "日本語": "ja",
    "한국어": "ko",
    "Français": "fr",
    "Deutsch": "de",
    "Italiano": "it",
    "Español": "es",
    "Русский": "ru",
    "Português": "pt",
    "العربية": "ar",
    "हिन्दी": "hi",
    "Malti": "mt",
}


def emit(event: str, **payload) -> None:
    print(json.dumps({"event": event, **payload}, ensure_ascii=False), flush=True)


def normalized_backend(value: str | None) -> str:
    backend = (value or START_BACKEND or "gemma").strip().lower()
    if backend == "local":
        return "gemma"
    if backend in {"gemma", "google", "bing", "deepl"}:
        return backend
    return "gemma"


def remove_control_characters(value: str) -> str:
    return "".join(ch for ch in value if ch in "\n\r\t" or not (ord(ch) < 32 or 0x7F <= ord(ch) <= 0x9F))


def target_for_google(lang: str) -> str:
    normalized = (lang or "en").strip().lower().replace("_", "-")
    return {
        "zh": "zh-CN",
        "zh-cn": "zh-CN",
        "zh-hans": "zh-CN",
        "zh-hant": "zh-TW",
        "zh-tw": "zh-TW",
    }.get(normalized, lang)


def target_for_bing(lang: str) -> str:
    normalized = (lang or "en").strip().lower().replace("_", "-")
    return {
        "zh": "zh-Hans",
        "zh-cn": "zh-Hans",
        "zh-hans": "zh-Hans",
        "zh-hant": "zh-Hant",
        "zh-tw": "zh-Hant",
    }.get(normalized, lang)


def target_for_deepl(lang: str) -> str:
    normalized = (lang or "en").strip().lower().replace("_", "-")
    return {
        "zh": "ZH",
        "zh-cn": "ZH",
        "zh-hans": "ZH",
        "zh-hant": "ZH-HANT",
        "zh-tw": "ZH-HANT",
        "en": "EN-US",
        "pt": "PT-PT",
    }.get(normalized, normalized.upper())


def detect_source_lang(text: str) -> str:
    if any("\u3040" <= char <= "\u30ff" for char in text):
        return "ja"
    if any("\u4e00" <= char <= "\u9fff" for char in text):
        return "zh"
    if any("\uac00" <= char <= "\ud7a3" for char in text):
        return "ko"
    return "en"


def chunk_text(text: str, max_chars: int) -> list[str]:
    if len(text) <= max_chars:
        return [text]
    parts = re.split(r"(\n\s*\n)", text)
    chunks: list[str] = []
    current = ""
    for part in parts:
        if len(part) > max_chars:
            if current:
                chunks.append(current)
                current = ""
            chunks.extend(part[index : index + max_chars] for index in range(0, len(part), max_chars))
        elif len(current) + len(part) > max_chars and current:
            chunks.append(current)
            current = part
        else:
            current += part
    if current:
        chunks.append(current)
    return chunks


class BaseTranslator:
    def translate(self, text: str, source_lang: str = "auto", target_lang: str = "zh") -> str:
        raise NotImplementedError

    def translate_with_retry(self, text: str, source_lang: str, target_lang: str, attempts: int = 3) -> str:
        if not text or not text.strip():
            return text
        last_exc = None
        for attempt in range(attempts):
            try:
                return self.translate(text, source_lang, target_lang)
            except Exception as exc:
                last_exc = exc
                if attempt < attempts - 1:
                    time.sleep(min(2 ** attempt, 4))
        raise RuntimeError(f"translation failed after {attempts} attempts: {last_exc}")


class GoogleMobileTranslator(BaseTranslator):
    def __init__(self) -> None:
        import requests

        self.session = requests.Session()
        self.endpoint = "https://translate.google.com/m"
        self.headers = {
            "User-Agent": (
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
            )
        }

    def translate(self, text: str, source_lang: str = "auto", target_lang: str = "zh") -> str:
        response = self.session.get(
            self.endpoint,
            params={"tl": target_for_google(target_lang), "sl": source_lang or "auto", "q": text[:5000]},
            headers=self.headers,
            timeout=30,
        )
        response.raise_for_status()
        matches = re.findall(r'(?s)class="(?:t0|result-container)">(.*?)<', response.text)
        if not matches:
            raise RuntimeError("Google response did not contain a translation result")
        return remove_control_characters(html.unescape(matches[0]))


class GoogleWebRPCTranslator(BaseTranslator):
    """Use the translation RPC called by the Google Translate web application.

    This is intentionally kept separate from the mobile-page scraper above: both
    are undocumented web endpoints and can change independently.
    """

    def __init__(self) -> None:
        import requests

        self.session = requests.Session()
        self.base_url = "https://translate.google.com"
        self.headers = {
            "User-Agent": (
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
            )
        }

    def _web_parameters(self, target_lang: str) -> dict[str, str | int]:
        response = self.session.get(
            self.base_url,
            params={"sl": "auto", "tl": target_for_google(target_lang), "op": "translate"},
            headers=self.headers,
            timeout=30,
        )
        response.raise_for_status()

        def extract(name: str) -> str:
            match = re.search(rf'"{re.escape(name)}":"(.*?)"', response.text)
            if not match:
                raise RuntimeError(f"Google web page did not contain {name}")
            return html.unescape(match.group(1)).replace(r"\\u003d", "=").replace(r"\\u0026", "&")

        return {
            "rpcids": "MkEWBc",
            "source-path": "/",
            "f.sid": extract("FdrFJe"),
            "bl": extract("cfb2h"),
            "hl": "en-US",
            "soc-app": 1,
            "soc-platform": 1,
            "soc-device": 1,
            "_reqid": 1000,
            "rt": "c",
        }

    @staticmethod
    def _parse_response(body: str) -> str:
        # batchexecute prepends a security prefix and a length line before JSON.
        json_start = body.find("\n[[")
        if json_start < 0:
            raise RuntimeError("Google RPC response did not contain a result envelope")
        envelopes = json.loads(body[json_start + 1 :])
        envelope = next(
            (item for item in envelopes if len(item) > 2 and item[0] == "wrb.fr" and item[1] == "MkEWBc"),
            None,
        )
        if not envelope or not isinstance(envelope[2], str):
            raise RuntimeError("Google RPC response did not contain a translation payload")
        payload = json.loads(envelope[2])
        result = payload[1][0][0]
        parts = result[5]
        if parts:
            return "".join(part[0] for part in parts if part and part[0])
        if result[0]:
            return result[0]
        raise RuntimeError("Google RPC response did not contain translated text")

    def translate(self, text: str, source_lang: str = "auto", target_lang: str = "zh") -> str:
        params = self._web_parameters(target_lang)
        request_payload = json.dumps(
            [[["MkEWBc", json.dumps([[text, source_lang or "auto", target_for_google(target_lang), True], [None]], separators=(",", ":")), None, "generic"]]],
            separators=(",", ":"),
        )
        response = self.session.post(
            f"{self.base_url}/_/TranslateWebserverUi/data/batchexecute",
            params=params,
            data={"f.req": request_payload},
            headers={**self.headers, "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8"},
            timeout=30,
        )
        response.raise_for_status()
        return remove_control_characters(self._parse_response(response.text))


class GoogleGTXTranslator(BaseTranslator):
    """Use the legacy Google Translate AJAX endpoint as a last Google fallback."""

    def __init__(self) -> None:
        import requests

        self.session = requests.Session()
        self.endpoint = "https://translate.googleapis.com/translate_a/single"
        self.headers = {
            "User-Agent": (
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
            )
        }

    def translate(self, text: str, source_lang: str = "auto", target_lang: str = "zh") -> str:
        response = self.session.get(
            self.endpoint,
            params={
                "client": "gtx",
                "sl": source_lang or "auto",
                "tl": target_for_google(target_lang),
                "dt": "t",
                "q": text,
            },
            headers=self.headers,
            timeout=30,
        )
        response.raise_for_status()
        parts = response.json()[0]
        translated = "".join(part[0] for part in parts if part and part[0])
        if not translated:
            raise RuntimeError("Google GTX response did not contain translated text")
        return remove_control_characters(translated)


class DeepLXTranslator(BaseTranslator):
    """Direct, no-key DeepL web JSON-RPC path based on the DeepLX project."""

    def __init__(self) -> None:
        import requests

        self.session = requests.Session()
        self.endpoint = "https://www2.deepl.com/jsonrpc"
        self.headers = {
            "Content-Type": "application/json",
            "User-Agent": "DeepL/1627620 CFNetwork/1498.700.2 Darwin/23.6.0",
            "X-App-Os-Name": "iOS",
            "X-Product": "translator",
        }

    def translate(self, text: str, source_lang: str = "auto", target_lang: str = "zh") -> str:
        source = "auto" if source_lang in {"", "auto"} else source_lang.upper()
        payload = {
            "jsonrpc": "2.0",
            "method": "LMT_handle_jobs",
            "id": random.randint(10_000_000, 99_999_999),
            "params": {
                "commonJobParams": {"mode": "translate", "formality": "default", "textType": "plaintext"},
                "lang": {"source_lang_user_selected": source, "target_lang": target_for_deepl(target_lang)},
                "jobs": [{
                    "kind": "default",
                    "preferred_num_beams": 4,
                    "raw_en_context_before": [],
                    "raw_en_context_after": [],
                    "sentences": [{"prefix": "", "text": text, "id": 0}],
                }],
                "timestamp": int(time.time() * 1000),
            },
        }
        response = self.session.post(self.endpoint, json=payload, headers=self.headers, timeout=30)
        response.raise_for_status()
        translated = "".join(
            sentence["text"]
            for translation in response.json()["result"]["translations"]
            for beam in translation.get("beams", [])[:1]
            for sentence in beam.get("sentences", [])
        )
        if not translated:
            raise RuntimeError("DeepL community response did not contain translated text")
        return remove_control_characters(translated)


class BingWebTranslator(BaseTranslator):
    def __init__(self) -> None:
        import requests

        self.session = requests.Session()
        self.endpoint = "https://www.bing.com/translator"
        self.headers = {
            "User-Agent": (
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0"
            )
        }

    def find_sid(self):
        response = self.session.get(self.endpoint, headers=self.headers, timeout=30)
        response.raise_for_status()
        url = response.url[:-10]
        ig_matches = re.findall(r'"ig":"(.*?)"', response.text)
        iid_matches = re.findall(r'data-iid="(.*?)"', response.text)
        token_matches = re.findall(r"params_AbusePreventionHelper\s=\s\[(.*?),\"(.*?)\",", response.text)
        if not ig_matches or not iid_matches or not token_matches:
            raise RuntimeError("Bing response did not contain translation tokens")
        key, token = token_matches[0]
        return url, ig_matches[0], iid_matches[-1], key, token

    def translate(self, text: str, source_lang: str = "auto", target_lang: str = "zh") -> str:
        translated_parts: list[str] = []
        for chunk in chunk_text(text, 900):
            translated_parts.append(self._translate_chunk(chunk, source_lang, target_lang))
        return "".join(translated_parts)

    def _translate_chunk(self, text: str, source_lang: str = "auto", target_lang: str = "zh") -> str:
        url, ig, iid, key, token = self.find_sid()
        from_lang = source_lang if source_lang and source_lang != "auto" else "en"
        response = self.session.post(
            f"{url}ttranslatev3?IG={ig}&IID={iid}",
            data={
                "fromLang": from_lang,
                "to": target_for_bing(target_lang),
                "text": text,
                "token": token,
                "key": key,
            },
            headers=self.headers,
            timeout=30,
        )
        response.raise_for_status()
        return response.json()[0]["translations"][0]["text"]


class BingEPTTranslator(BingWebTranslator):
    """Bing's Enhanced Phrase Translation web route.

    This route is used by the community-maintained bing-translate-api project.
    It is still an undocumented web integration, but is a distinct request path
    from the legacy Bing route and supports larger text segments.
    """

    def translate(self, text: str, source_lang: str = "auto", target_lang: str = "zh") -> str:
        translated_parts: list[str] = []
        for chunk in chunk_text(text, 3000):
            translated_parts.append(self._translate_ept_chunk(chunk, source_lang, target_lang))
        return "".join(translated_parts)

    def _translate_ept_chunk(self, text: str, source_lang: str, target_lang: str) -> str:
        url, ig, iid, key, token = self.find_sid()
        from_lang = source_lang if source_lang and source_lang != "auto" else "auto-detect"
        response = self.session.post(
            f"{url}ttranslatev3?isVertical=1&IG={ig}&IID={iid}&SFX=1&ref=TThis&edgepdftranslator=1",
            data={
                "fromLang": from_lang,
                "to": target_for_bing(target_lang),
                "text": text,
                "token": token,
                "key": key,
                "tryFetchingGenderDebiasedTranslations": "true",
            },
            headers={**self.headers, "Referer": f"{url}translator"},
            timeout=30,
        )
        response.raise_for_status()
        return response.json()[0]["translations"][0]["text"]


class TranslateWorker:
    def __init__(self) -> None:
        self.model = None
        self.tokenizer = None
        self.stream_generate = None
        self.stop_event = Event()
        self.processing_thread: Thread | None = None
        self.current_gen_id = 0
        self.cloud_translators: dict[str, BaseTranslator] = {}
        self.local_model_ready = False
        self.model_load_lock = Lock()

    def load(self) -> None:
        if normalized_backend(START_BACKEND) in {"google", "bing", "deepl"}:
            emit("status", text=f"Using {normalized_backend(START_BACKEND).title()} Translate...")
            emit("ready")
            return
        self.load_model(emit_ready=True)

    def load_model(self, emit_ready: bool) -> bool:
        with self.model_load_lock:
            if self.local_model_ready:
                if emit_ready:
                    emit("ready")
                return True
            emit("status", text="Loading TranslateGemma...")
            try:
                if os.environ.get("TRANSLATE_APPKIT_SKIP_MODEL") == "1":
                    self.local_model_ready = True
                    if emit_ready:
                        emit("ready")
                    return True
                from mlx_lm import load, stream_generate

                self.stream_generate = stream_generate
                self.model, self.tokenizer = load(MODEL_PATH, model_config={"trust_remote_code": True})
                self.local_model_ready = True
                if emit_ready:
                    emit("ready")
                return True
            except Exception as exc:
                traceback.print_exc(file=sys.stderr)
                emit("error", title="Model Load Error", message=str(exc))
                return False

    def stop(self) -> None:
        self.stop_event.set()
        emit("stopped")

    def prepare_backend(self, backend: str | None) -> None:
        self.stop_event.set()
        self.current_gen_id += 1
        gen_id = self.current_gen_id
        old_thread = self.processing_thread
        selected_backend = normalized_backend(backend)

        def run() -> None:
            if old_thread and old_thread.is_alive():
                old_thread.join()
            self.stop_event.clear()
            try:
                if selected_backend == "gemma":
                    if self.load_model(emit_ready=False) and gen_id == self.current_gen_id:
                        emit("backend_ready", backend=selected_backend)
                else:
                    self.get_cloud_translator(selected_backend)
                    if gen_id == self.current_gen_id:
                        emit("backend_ready", backend=selected_backend)
            except Exception as exc:
                traceback.print_exc(file=sys.stderr)
                emit("error", title="Backend Error", message=str(exc))

        self.processing_thread = Thread(target=run, daemon=True)
        self.processing_thread.start()

    def translate(self, text: str, target_language: str, style: str, backend: str | None = None) -> None:
        self.stop_event.set()
        self.current_gen_id += 1
        gen_id = self.current_gen_id
        old_thread = self.processing_thread
        selected_backend = normalized_backend(backend)

        def run() -> None:
            if old_thread and old_thread.is_alive():
                old_thread.join()
            self.stop_event.clear()
            clean_text = text.strip().strip('"').strip("'")
            if selected_backend in {"google", "bing", "deepl"}:
                self._translate_cloud(clean_text, target_language, selected_backend, gen_id)
            else:
                self._generate(clean_text, target_language, style, gen_id)

        self.processing_thread = Thread(target=run, daemon=True)
        self.processing_thread.start()

    def get_cloud_translator(self, backend: str) -> BaseTranslator:
        if backend not in self.cloud_translators:
            if backend == "google":
                self.cloud_translators[backend] = GoogleMobileTranslator()
            elif backend == "deepl":
                self.cloud_translators[backend] = DeepLXTranslator()
            elif backend == "bing_ept":
                self.cloud_translators[backend] = BingEPTTranslator()
            elif backend == "bing":
                self.cloud_translators[backend] = BingWebTranslator()
            else:
                raise ValueError(f"Unsupported cloud backend: {backend}")
        return self.cloud_translators[backend]

    def _google_translator_chain(self) -> list[tuple[str, BaseTranslator]]:
        available = {
            "google_mobile": ("Google mobile web", self.get_cloud_translator("google")),
            "google_rpc": ("Google web RPC", GoogleWebRPCTranslator()),
            "google_gtx": ("Google GTX", GoogleGTXTranslator()),
        }
        requested_order = [part.strip().lower() for part in GOOGLE_FALLBACK_ORDER.split(",")]
        chain = [available.pop(name) for name in requested_order if name in available]
        # Keep all supported paths available if an older or malformed preference is found.
        return chain + list(available.values())

    def _translate_with_fallback(self, text: str, source_lang: str, target_lang: str, preferred_backend: str) -> str:
        google_chain = self._google_translator_chain()
        bing_chain = [
            ("Bing EPT", self.get_cloud_translator("bing_ept")),
            ("Bing legacy web", self.get_cloud_translator("bing")),
        ]
        service_chains = {
            "google": google_chain,
            "bing": bing_chain,
            "deepl": [],
        }
        configured_order = [
            service.strip().lower()
            for service in CLOUD_FALLBACK_ORDER.replace("→", ",").split(",")
        ]
        service_order = [preferred_backend] + [
            service for service in configured_order if service in service_chains and service != preferred_backend
        ]
        service_order.extend(service for service in service_chains if service not in service_order)
        translators: list[tuple[str, BaseTranslator]] = []
        for service in service_order:
            if service == "deepl":
                translators.append(("DeepL community web", self.get_cloud_translator("deepl")))
            else:
                translators.extend(service_chains[service])
        errors: list[str] = []
        for name, translator in translators:
            try:
                return translator.translate_with_retry(text, source_lang, target_lang)
            except Exception as exc:
                errors.append(f"{name}: {exc}")
                emit("status", text=f"{name} unavailable; trying the next service...")
        raise RuntimeError("All configured cloud translation paths failed. " + " | ".join(errors))

    def _translate_cloud(self, input_content: str, target_language: str, backend: str, gen_id: int) -> None:
        try:
            target_code = LANG_MAP.get(target_language, "en")
            source_code = detect_source_lang(input_content)
            emit("started")
            max_chars = 4500 if backend in {"google", "deepl"} else 900
            translated_parts: list[str] = []
            for chunk in chunk_text(input_content, max_chars):
                if self.stop_event.is_set() or gen_id != self.current_gen_id:
                    emit("stopped")
                    return
                translated_parts.append(self._translate_with_fallback(chunk, source_code, target_code, backend))
            if self.stop_event.is_set() or gen_id != self.current_gen_id:
                emit("stopped")
                return
            emit("replace", text="".join(translated_parts))
            emit("complete")
        except Exception as exc:
            traceback.print_exc(file=sys.stderr)
            emit("error", title="Translation Error", message=str(exc))

    def _generate(self, input_content: str, target_language: str, style: str, gen_id: int) -> None:
        if os.environ.get("TRANSLATE_APPKIT_SKIP_MODEL") == "1":
            emit("started")
            emit("replace", text=f"[Preview mode]\nTarget: {target_language}\nStyle: {style}\n\n{input_content}")
            emit("complete")
            return
        if not self.model or not self.tokenizer or not self.stream_generate:
            if not self.load_model(emit_ready=False):
                return

        try:
            target_code = LANG_MAP.get(target_language, "en")
            source_code = detect_source_lang(input_content)
            processed_text = input_content
            warning_prefix = ""

            if style == "Default":
                clean_str = input_content.strip()
                has_punctuation = any(char in "，。！？；：,.!?;:" for char in clean_str)
                space_count = clean_str.count(" ")
                cjk_count = sum(
                    1
                    for char in clean_str
                    if "\u4e00" <= char <= "\u9fff" or "\u3040" <= char <= "\u30ff"
                )
                if cjk_count > 0:
                    is_likely_word = not has_punctuation and len(clean_str) <= 6
                else:
                    is_likely_word = not has_punctuation and (space_count == 0 or len(clean_str) < 20)
                if is_likely_word:
                    style = "Dictionary"

            if style == "Dictionary":
                cjk_count = sum(
                    1
                    for char in input_content
                    if "\u4e00" <= char <= "\u9fff" or "\u3040" <= char <= "\u30ff"
                )
                has_punctuation = any(char in "，。！？；：,.!?;:" for char in input_content)
                is_sentence = len(input_content.split()) > 1 or has_punctuation or len(input_content) > 20 or cjk_count > 6
                if is_sentence:
                    warning_prefix = "⚠️ [Mode Switch: Input detected as a phrase/sentence. Switching to Default style...]\n\n"
                    style = "Default"
                else:
                    processed_text = (
                        "You are a dictionary formatter.\n"
                        "Your task is to output EXACTLY 5 lines and NOTHING ELSE.\n"
                        "Any extra text, titles, labels, numbering, markdown, or explanations are STRICTLY FORBIDDEN.\n\n"
                        "FORMAT (STRICT):\n"
                        "Line 1: IPA pronunciation enclosed in slashes, and ONLY IPA. Example: /kæt/\n"
                        "Line 2: Part of speech ONLY. Example: noun, verb, adjective\n"
                        f"Line 3: Definition written in {target_code}. No labels.\n"
                        "Line 4: List one example sentence in the original language of WORD. No labels.\n"
                        f"Line 5: Translation of line 4 written in {target_code}. No labels.\n\n"
                        "NEGATIVE CONSTRAINTS (DO NOT DO THESE):\n"
                        "- Do NOT use words like Definition, Example, Translation\n"
                        "- Do NOT use headers, bullet points, numbers, or markdown\n"
                        "- Do NOT add explanations or notes\n"
                        "- Do NOT repeat the word\n\n"
                        "WORD: "
                        + input_content
                    )

            if style == "Academic":
                processed_text = f"(Translate the following text into {target_code} using a formal, academic, and scientific tone):\n{input_content}"
            elif style == "Web Chat":
                processed_text = f"(Translate the following text into {target_code} using an casual tone suitable for online messaging. You can use common abbreviations, slang like a real person would):\n{input_content}"
            elif style == "Casual":
                processed_text = f"(Translate the following text into {target_code} using a natural, casual, and conversational tone):\n{input_content}"

            payload = {
                "type": "text",
                "source_lang_code": source_code,
                "target_lang_code": target_code,
                "text": processed_text,
                "image": None,
            }
            messages = [{"role": "user", "content": [payload]}]
            if hasattr(self.tokenizer, "apply_chat_template"):
                prompt = self.tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
            else:
                prompt = f"Translate from {source_code} to {target_code}:\n{processed_text}"

            emit("started")
            first_token = True
            for response in self.stream_generate(self.model, self.tokenizer, prompt, max_tokens=1024):
                if self.stop_event.is_set() or gen_id != self.current_gen_id:
                    emit("token", text="\n[Stopped]")
                    return

                text_chunk = response.text
                should_stop = False
                for token in ["<end_of_turn>", "<eos>", "<bos>"]:
                    if token in text_chunk:
                        should_stop = True
                        text_chunk = text_chunk.replace(token, "")

                if text_chunk:
                    if first_token:
                        emit("replace", text=warning_prefix)
                        first_token = False
                    emit("token", text=text_chunk)

                if should_stop:
                    break
            emit("complete")
        except Exception as exc:
            traceback.print_exc(file=sys.stderr)
            emit("error", title="Translation Error", message=str(exc))

    def run(self) -> None:
        self.load()
        for line in sys.stdin:
            try:
                command = json.loads(line)
            except json.JSONDecodeError:
                continue
            action = command.get("action")
            if action == "translate":
                self.translate(
                    command.get("text", ""),
                    command.get("target", "English"),
                    command.get("style", "Default"),
                    command.get("backend"),
                )
            elif action == "prepare_backend":
                self.prepare_backend(command.get("backend"))
            elif action == "stop":
                self.stop()
            elif action == "quit":
                self.stop()
                break


if __name__ == "__main__":
    TranslateWorker().run()
