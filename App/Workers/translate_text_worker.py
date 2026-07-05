#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import sys
import traceback
from threading import Event, Thread


MODEL_PATH = os.environ.get("TRANSLATE_TEXT_MODEL", "").strip()

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


def detect_source_lang(text: str) -> str:
    if any("\u3040" <= char <= "\u30ff" for char in text):
        return "ja"
    if any("\u4e00" <= char <= "\u9fff" for char in text):
        return "zh"
    if any("\uac00" <= char <= "\ud7a3" for char in text):
        return "ko"
    return "en"


class TranslateWorker:
    def __init__(self) -> None:
        self.model = None
        self.tokenizer = None
        self.stream_generate = None
        self.stop_event = Event()
        self.processing_thread: Thread | None = None
        self.current_gen_id = 0

    def load(self) -> None:
        emit("status", text="Loading TranslateGemma...")
        try:
            if os.environ.get("TRANSLATE_APPKIT_SKIP_MODEL") == "1":
                emit("ready")
                return
            if not MODEL_PATH:
                emit(
                    "error",
                    title="Model Path Missing",
                    message="Open Settings and select your local TranslateGemma model folder.",
                )
                return
            from mlx_lm import load, stream_generate

            self.stream_generate = stream_generate
            self.model, self.tokenizer = load(MODEL_PATH, model_config={"trust_remote_code": True})
            emit("ready")
        except Exception as exc:
            traceback.print_exc(file=sys.stderr)
            emit("error", title="Model Load Error", message=str(exc))

    def stop(self) -> None:
        self.stop_event.set()
        emit("stopped")

    def translate(self, text: str, target_language: str, style: str) -> None:
        self.stop_event.set()
        self.current_gen_id += 1
        gen_id = self.current_gen_id
        old_thread = self.processing_thread

        def run() -> None:
            if old_thread and old_thread.is_alive():
                old_thread.join()
            self.stop_event.clear()
            self._generate(text.strip().strip('"').strip("'"), target_language, style, gen_id)

        self.processing_thread = Thread(target=run, daemon=True)
        self.processing_thread.start()

    def _generate(self, input_content: str, target_language: str, style: str, gen_id: int) -> None:
        if os.environ.get("TRANSLATE_APPKIT_SKIP_MODEL") == "1":
            emit("started")
            emit("replace", text=f"[Preview mode]\nTarget: {target_language}\nStyle: {style}\n\n{input_content}")
            emit("complete")
            return
        if not self.model or not self.tokenizer or not self.stream_generate:
            emit("error", title="Not Ready", message="TranslateGemma is not loaded yet.")
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
                self.translate(command.get("text", ""), command.get("target", "English"), command.get("style", "Default"))
            elif action == "stop":
                self.stop()
            elif action == "quit":
                self.stop()
                break


if __name__ == "__main__":
    TranslateWorker().run()
